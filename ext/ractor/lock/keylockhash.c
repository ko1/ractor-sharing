#include "lock.h"
#include "ruby/st.h"
#include "rcuhash.h"

/* Ractor::KeyLockHash - a hash with one lock per key, near enough.
 *
 * Ractor::LockHash is the table lock: one lock over the whole hash, so a
 * section is atomic across its keys and unrelated keys wait for each other.
 * This is the row lock: an update touches one key under one lock, and updates
 * to unrelated keys run in parallel.  Nothing here is atomic across two keys;
 * that is LockHash's job (or Ractor::TVar's).
 *
 * "Near enough": the implementation is sharded, the textbook name is lock
 * striping.  Keys hash onto a fixed number of shards, each a table with a lock
 * of its own, so two keys sometimes share a lock.  That costs a collision now
 * and then and buys freedom from per-entry lock lifetime problems.
 *
 * A plain write is []=, with no ceremony: one key's write is atomic on its
 * own.  #update exists for one reason only, computing the new value from the
 * old one, read and stored under the same hold of that key's lock; its block
 * runs exactly once.  The claim idiom falls out: whether the block saw nil
 * tells you whether you won.
 *
 *     mine = false
 *     m.update(id) {|v| v ? v : (mine = true; :claimed) }
 */

#define KLH_NSHARDS 64

static VALUE rb_cRactorKeyLockHash;
static ID id_plus;

struct klh_shard {
    struct rcu_shard rcu;       /* lock-free readable; writers hold lock */
    struct rs_lock lock;        /* writer mutex + guard for the block methods */
};

struct keylockhash {
    struct klh_shard shards[KLH_NSHARDS];
};

/* An immediate (Symbol, Integer-as-Fixnum, nil/true/false, flonum) is its own
 * VALUE and eql? only to the identical VALUE, so it can be its own hash and
 * skip rb_hash -- which perf put at ~6%% of an update.  Anything else (a String
 * key, a frozen object) must go through rb_hash: two eql values are different
 * VALUEs and have to hash alike. */
static inline st_index_t
klh_hash(VALUE key)
{
    if (SPECIAL_CONST_P(key)) return (st_index_t)key;
    return (st_index_t)NUM2LONG(rb_hash(key));
}

static void
klh_mark(void *ptr)
{
    struct keylockhash *kh = ptr;
    for (int i = 0; i < KLH_NSHARDS; i++) rcu_shard_mark(&kh->shards[i].rcu);
}

static void
klh_free(void *ptr)
{
    struct keylockhash *kh = ptr;
    for (int i = 0; i < KLH_NSHARDS; i++) {
        rcu_shard_destroy(&kh->shards[i].rcu);
        rs_lock_destroy(&kh->shards[i].lock);
    }
    ruby_xfree(kh);
}

static size_t
klh_memsize(const void *ptr)
{
    const struct keylockhash *kh = ptr;
    size_t n = sizeof(struct keylockhash);
    for (int i = 0; i < KLH_NSHARDS; i++) n += rcu_shard_memsize(&kh->shards[i].rcu);
    return n;
}

static const rb_data_type_t klh_data_type = {
    "Ractor::KeyLockHash",
    {klh_mark, klh_free, klh_memsize, NULL},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE
};

static struct keylockhash *
klh_ptr(VALUE self)
{
    struct keylockhash *kh;
    TypedData_Get_Struct(self, struct keylockhash, &klh_data_type, kh);
    return kh;
}

static void
klh_check_shareable(VALUE val)
{
    if (RB_UNLIKELY(!rb_ractor_shareable_p(val))) {
        rb_raise(rb_eArgError, "only shareable object are allowed");
    }
}

static VALUE
klh_alloc(VALUE klass)
{
    struct keylockhash *kh;
    VALUE obj = TypedData_Make_Struct(klass, struct keylockhash, &klh_data_type, kh);
    for (int i = 0; i < KLH_NSHARDS; i++) {
        rcu_shard_init(&kh->shards[i].rcu);
        rs_lock_init(&kh->shards[i].lock);
    }
    return obj;
}

static int
klh_copy_pair(VALUE key, VALUE value, VALUE selfv)
{
    st_index_t h;
    key = rs_hash_key(key);
    klh_check_shareable(key);
    value = rs_shareable_value(value);
    h = klh_hash(key);
    /* single-threaded: nobody else has seen self yet */
    rcu_insert(&klh_ptr((VALUE)selfv)->shards[h % KLH_NSHARDS].rcu, h, key, value);
    return ST_CONTINUE;
}

static VALUE
klh_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE init = Qnil;
    rb_check_frozen(self);   /* send(:initialize) again would write past the locks */
    rb_scan_args(argc, argv, "01", &init);
    if (!NIL_P(init)) {
        Check_Type(init, T_HASH);
        rb_hash_foreach(init, klh_copy_pair, self);
    }
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
    return self;
}

/* --- guarded bodies ------------------------------------------------------- */

struct klh_op {
    struct klh_shard *shard;
    st_index_t hash;
    VALUE key;
    VALUE value;
};

/* Fills shard + hash for +key+; hash is computed once. */
static struct klh_op
klh_op_make(VALUE self, VALUE key, VALUE value)
{
    st_index_t h = klh_hash(key);
    struct klh_op op = { &klh_ptr(self)->shards[h % KLH_NSHARDS], h, key, value };
    return op;
}

static VALUE
klh_lookup_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    return rcu_get(&op->shard->rcu, op->hash, op->key);
}

/* store_if_absent: return the value if the key is set, otherwise the block runs
 * ONCE under this key's lock and its result is stored.  The hit path -- the
 * common one in a cache -- never yields, so it costs a read, not an update. */
static VALUE
klh_store_if_absent_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE found = rcu_get(&op->shard->rcu, op->hash, op->key);
    VALUE computed;

    if (!RB_UNDEF_P(found)) return found;
    computed = rs_shareable_value(rb_yield(op->key));
    rcu_insert(&op->shard->rcu, op->hash, op->key, computed);
    return computed;
}

static VALUE
klh_update_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE found = rcu_get(&op->shard->rcu, op->hash, op->key);
    VALUE old = RB_UNDEF_P(found) ? Qnil : found;
    VALUE next = rs_shareable_value(rb_yield(old));
    rcu_insert(&op->shard->rcu, op->hash, op->key, next);
    return next;
}

/* (old or 0) + amount, stored under the key's lock.  A missing key counts as
 * zero, the way ActorHash#increment counts it: the tally shape needs no
 * seeding.  Fixnums that stay Fixnums skip the dispatch. */
static VALUE
klh_increment_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE found = rcu_get(&op->shard->rcu, op->hash, op->key);
    VALUE old = RB_UNDEF_P(found) ? INT2FIX(0) : found;
    VALUE next = rs_fixnum_add(old, op->value);
    if (RB_UNDEF_P(next)) {
        next = rs_shareable_value(rb_funcall(old, id_plus, 1, op->value));
    }
    rcu_insert(&op->shard->rcu, op->hash, op->key, next);
    return next;
}

static VALUE
klh_aset_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    rcu_insert(&op->shard->rcu, op->hash, op->key, op->value);
    return op->value;
}

static VALUE
klh_delete_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE old = rcu_delete(&op->shard->rcu, op->hash, op->key);
    return RB_UNDEF_P(old) ? Qnil : old;
}

static int
klh_collect_key(VALUE key, VALUE value, void *ary)
{
    rb_ary_push((VALUE)ary, key);
    return ST_CONTINUE;
}

static int
klh_collect_pair(VALUE key, VALUE value, void *hash)
{
    rb_hash_aset((VALUE)hash, key, value);
    return ST_CONTINUE;
}

static VALUE
klh_collect_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    rcu_shard_foreach(&op->shard->rcu,
                      RB_TYPE_P(op->value, T_ARRAY) ? klh_collect_key : klh_collect_pair,
                      (void *)op->value);
    return Qnil;
}

/* One key's #hash or #eql? reaching back into this map raises NestedLockError
 * rather than deadlocking: the inner call may want a shard this thread does
 * not hold, so unlike LockHash there is no safe reentrant path. */
#define KLH_GUARDED(self, op, body) \
    rs_guarded((self), &(op)->shard->lock, (body), (op), false, \
               "one key is already in hand; two keys together is Ractor::LockHash's job")

/* --- methods -------------------------------------------------------------- */

/* A read whose key is an immediate takes NO lock at all: see rcu_lookup.
 * Returns Qundef for a non-immediate key so the caller falls back to the
 * guarded (locked) path, where a String key's #eql? may run Ruby. */
static VALUE
klh_fast_lookup(VALUE self, VALUE key)
{
    st_index_t h;
    struct klh_shard *shard;

    if (!SPECIAL_CONST_P(key)) return Qundef;
    /* Nesting is still refused: inside any update, a read raises. */
    if (RB_UNLIKELY(!NIL_P(rs_held(rb_thread_current())))) return Qundef;

    h = klh_hash(key);
    shard = &klh_ptr(self)->shards[h % KLH_NSHARDS];
    /* No lock: rcu_lookup loads the table and walks immutable nodes, writing
     * nothing shared, so reads scale.  Immediate key => identity compare, no
     * Ruby, no safepoint in the window, so GC (the grace period) cannot free a
     * node this walk is on. */
    return rcu_lookup(&shard->rcu, h, key);
}

/*
 *  call-seq:
 *     keylockhash[key] -> value or nil
 *
 *  Reads one key under that key's shard lock.  Unrelated keys do not wait.
 */
static VALUE
klh_aref(VALUE self, VALUE key)
{
    VALUE found = klh_fast_lookup(self, key);
    if (!RB_UNDEF_P(found)) return found;
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) return Qnil;
    {
        struct klh_op op = klh_op_make(self, key, Qnil);
        VALUE f = KLH_GUARDED(self, &op, klh_lookup_body);
        return RB_UNDEF_P(f) ? Qnil : f;
    }
}

/*
 *  call-seq:
 *     keylockhash.fetch(key)            -> value or KeyError
 *     keylockhash.fetch(key, default)   -> value or default
 *     keylockhash.fetch(key) {|k| ... } -> value or block result
 *
 *  The default and the block run with the lock released.
 */
static VALUE
klh_fetch(int argc, VALUE *argv, VALUE self)
{
    VALUE key, def, found;
    struct klh_op op;

    rb_check_arity(argc, 1, 2);
    key = argv[0];
    def = argc > 1 ? argv[1] : Qundef;

    found = klh_fast_lookup(self, key);
    if (RB_UNDEF_P(found)) {
        op = klh_op_make(self, key, Qnil);
        found = SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))
              ? Qundef : KLH_GUARDED(self, &op, klh_lookup_body);
    }
    if (!RB_UNDEF_P(found)) return found;
    if (rb_block_given_p()) return rb_yield(key);
    if (!RB_UNDEF_P(def)) return def;
    rb_raise(rb_eKeyError, "key not found: %+"PRIsVALUE, key);
}

static VALUE
klh_key_p(VALUE self, VALUE key)
{
    struct klh_op op;
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) {
        return RB_UNDEF_P(klh_fast_lookup(self, key)) ? Qfalse : Qtrue;
    }
    op = klh_op_make(self, key, Qnil);
    return RB_UNDEF_P(KLH_GUARDED(self, &op, klh_lookup_body)) ? Qfalse : Qtrue;
}

/*
 *  call-seq:
 *     keylockhash.update(key) {|value_or_nil| new_value } -> new_value
 *
 *  Reads, yields and stores under that key's lock: an atomic
 *  read-modify-write for one key, and the block runs exactly once.  Yields
 *  nil for a missing key, so "whether the block saw nil" is "whether you
 *  created it" -- the put-if-absent idiom needs nothing more.
 */
/*
 *  call-seq:
 *     keylockhash.store_if_absent(key) {|key| computed } -> value
 *
 *  The value at +key+ if it is set; otherwise the block runs once, under that
 *  key's lock, and its result is stored and returned -- the per-key analogue of
 *  Ractor.store_if_absent.  This is the memoize / cache primitive: simultaneous
 *  misses on one key compute once and the rest read the answer, and a hit never
 *  runs the block at all.
 */
static VALUE
klh_store_if_absent(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();
    key = rs_hash_key(key);
    klh_check_shareable(key);   /* may insert it */
    op = klh_op_make(self, key, Qnil);
    return KLH_GUARDED(self, &op, klh_store_if_absent_body);
}

static VALUE
klh_update(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();
    key = rs_hash_key(key);     /* may insert it */
    klh_check_shareable(key);
    op = klh_op_make(self, key, Qnil);
    return KLH_GUARDED(self, &op, klh_update_body);
}

/*
 *  call-seq:
 *     keylockhash.increment(key, by = 1) -> new value
 *
 *  Adds +by+ under that key's lock; a missing key counts as zero.  The same
 *  as <code>update(key) {|v| (v || 0) + by }</code>.
 */
static VALUE
klh_increment(int argc, VALUE *argv, VALUE self)
{
    VALUE key, by;
    struct klh_op op;

    rb_check_arity(argc, 1, 2);
    key = rs_hash_key(argv[0]);
    klh_check_shareable(key);   /* may insert it */
    by = argc < 2 ? INT2FIX(1) : argv[1];
    op = klh_op_make(self, key, by);
    return KLH_GUARDED(self, &op, klh_increment_body);
}

/*
 *  call-seq:
 *     keylockhash[key] = value -> value
 *
 *  Stores under that key's lock.  No ceremony: a plain write is atomic on its
 *  own here, because nothing in this class is atomic across two keys anyway.
 *  Reach for #update only when the new value is computed from the old one.
 */
static VALUE
klh_aset(VALUE self, VALUE key, VALUE value)
{
    struct klh_op op;

    key = rs_hash_key(key);
    klh_check_shareable(key);
    value = rs_shareable_value(value);
    op = klh_op_make(self, key, value);
    return KLH_GUARDED(self, &op, klh_aset_body);
}

/*
 *  call-seq:
 *     keylockhash.delete(key) -> old value or nil
 */
static VALUE
klh_delete(VALUE self, VALUE key)
{
    struct klh_op op = klh_op_make(self, key, Qnil);
    return KLH_GUARDED(self, &op, klh_delete_body);
}

/* keys and to_h visit the shards one at a time, each under its own lock: a
 * plain mutable copy, consistent per shard but NOT a snapshot of the whole
 * map at one moment.  A cross-key snapshot is LockHash territory. */
static VALUE
klh_keys(VALUE self)
{
    VALUE ary = rb_ary_new();
    struct keylockhash *kh = klh_ptr(self);

    for (int i = 0; i < KLH_NSHARDS; i++) {
        struct klh_op op = { &kh->shards[i], 0, Qnil, ary };
        KLH_GUARDED(self, &op, klh_collect_body);
    }
    return ary;
}

static VALUE
klh_to_h(VALUE self)
{
    VALUE hash = rb_hash_new();
    struct keylockhash *kh = klh_ptr(self);

    for (int i = 0; i < KLH_NSHARDS; i++) {
        struct klh_op op = { &kh->shards[i], 0, Qnil, hash };
        KLH_GUARDED(self, &op, klh_collect_body);
    }
    return hash;
}

static VALUE
klh_inspect(VALUE self)
{
    if (!NIL_P(rs_held(rb_thread_current()))) {
        return rb_sprintf("#<%"PRIsVALUE" ...>", rb_obj_class(self));
    }
    return rb_sprintf("#<%"PRIsVALUE" %+"PRIsVALUE">", rb_obj_class(self), klh_to_h(self));
}

void
Init_keylockhash_class(void)
{
    id_plus = rb_intern("+");
    rb_cRactorKeyLockHash = rb_define_class_under(rb_cRactor, "KeyLockHash", rb_cObject);
    rb_define_alloc_func(rb_cRactorKeyLockHash, klh_alloc);
    rb_define_method(rb_cRactorKeyLockHash, "initialize", klh_initialize, -1);

    rb_define_method(rb_cRactorKeyLockHash, "[]", klh_aref, 1);
    rb_define_method(rb_cRactorKeyLockHash, "fetch", klh_fetch, -1);
    rb_define_method(rb_cRactorKeyLockHash, "key?", klh_key_p, 1);
    rb_define_method(rb_cRactorKeyLockHash, "update", klh_update, 1);
    rb_define_method(rb_cRactorKeyLockHash, "store_if_absent", klh_store_if_absent, 1);
    rb_define_method(rb_cRactorKeyLockHash, "increment", klh_increment, -1);
    rb_define_method(rb_cRactorKeyLockHash, "[]=", klh_aset, 2);
    rb_define_method(rb_cRactorKeyLockHash, "delete", klh_delete, 1);
    rb_define_method(rb_cRactorKeyLockHash, "keys", klh_keys, 0);
    rb_define_method(rb_cRactorKeyLockHash, "to_h", klh_to_h, 0);
    rb_define_method(rb_cRactorKeyLockHash, "inspect", klh_inspect, 0);
}
