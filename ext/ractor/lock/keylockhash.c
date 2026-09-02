#include "lock.h"
#include "ruby/st.h"

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
    st_table *tbl;              /* shareable VALUE => shareable VALUE */
    struct rs_lock lock;
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

static st_index_t
klh_key_hash(st_data_t key)
{
    return klh_hash((VALUE)key);
}

static int
klh_key_cmp(st_data_t a, st_data_t b)
{
    return rb_eql((VALUE)a, (VALUE)b) ? 0 : 1;
}

static const struct st_hash_type klh_type = { klh_key_cmp, klh_key_hash };

static int
klh_mark_i(st_data_t key, st_data_t value, st_data_t arg)
{
    rb_gc_mark((VALUE)key);
    rb_gc_mark((VALUE)value);
    return ST_CONTINUE;
}

static void
klh_mark(void *ptr)
{
    struct keylockhash *kh = ptr;
    for (int i = 0; i < KLH_NSHARDS; i++) {
        st_foreach(kh->shards[i].tbl, klh_mark_i, 0);
    }
}

static void
klh_free(void *ptr)
{
    struct keylockhash *kh = ptr;
    for (int i = 0; i < KLH_NSHARDS; i++) {
        st_free_table(kh->shards[i].tbl);
        rs_lock_destroy(&kh->shards[i].lock);
    }
    ruby_xfree(kh);
}

static size_t
klh_memsize(const void *ptr)
{
    const struct keylockhash *kh = ptr;
    size_t n = sizeof(struct keylockhash);
    for (int i = 0; i < KLH_NSHARDS; i++) n += st_memsize(kh->shards[i].tbl);
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

/* The key's #hash runs here, outside every lock. */
static struct klh_shard *
klh_shard_for(VALUE self, VALUE key)
{
    return &klh_ptr(self)->shards[klh_hash(key) % KLH_NSHARDS];
}

static VALUE
klh_alloc(VALUE klass)
{
    struct keylockhash *kh;
    VALUE obj = TypedData_Make_Struct(klass, struct keylockhash, &klh_data_type, kh);
    for (int i = 0; i < KLH_NSHARDS; i++) {
        kh->shards[i].tbl = st_init_table(&klh_type);
        rs_lock_init(&kh->shards[i].lock);
    }
    return obj;
}

static int
klh_copy_pair(VALUE key, VALUE value, VALUE selfv)
{
    key = rs_hash_key(key);
    klh_check_shareable(key);
    value = rs_shareable_value(value);
    /* single-threaded: nobody else has seen self yet */
    st_insert(klh_shard_for((VALUE)selfv, key)->tbl, (st_data_t)key, (st_data_t)value);
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
    VALUE key;
    VALUE value;
};

static VALUE
klh_lookup_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    st_data_t found;

    if (st_lookup(op->shard->tbl, (st_data_t)op->key, &found)) return (VALUE)found;
    return Qundef;
}

/* store_if_absent: return the value if the key is set, otherwise the block runs
 * ONCE under this key's lock and its result is stored.  The hit path -- the
 * common one in a cache -- never yields, so it costs a read, not an update. */
static VALUE
klh_store_if_absent_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    st_data_t found;
    VALUE computed;

    if (st_lookup(op->shard->tbl, (st_data_t)op->key, &found)) return (VALUE)found;
    computed = rs_shareable_value(rb_yield(op->key));
    st_insert(op->shard->tbl, (st_data_t)op->key, (st_data_t)computed);
    return computed;
}

static VALUE
klh_update_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    st_data_t found;
    VALUE old = Qnil, next;

    if (st_lookup(op->shard->tbl, (st_data_t)op->key, &found)) old = (VALUE)found;
    next = rs_shareable_value(rb_yield(old));
    st_insert(op->shard->tbl, (st_data_t)op->key, (st_data_t)next);
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
    st_data_t found;
    VALUE old = INT2FIX(0), next;

    if (st_lookup(op->shard->tbl, (st_data_t)op->key, &found)) old = (VALUE)found;
    next = rs_fixnum_add(old, op->value);
    if (RB_UNDEF_P(next)) {
        next = rs_shareable_value(rb_funcall(old, id_plus, 1, op->value));
    }
    st_insert(op->shard->tbl, (st_data_t)op->key, (st_data_t)next);
    return next;
}

static VALUE
klh_aset_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;

    st_insert(op->shard->tbl, (st_data_t)op->key, (st_data_t)op->value);
    return op->value;
}

static VALUE
klh_delete_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    st_data_t key = (st_data_t)op->key, old;

    if (st_delete(op->shard->tbl, &key, &old)) return (VALUE)old;
    return Qnil;
}

static int
klh_collect_key(st_data_t key, st_data_t value, st_data_t ary)
{
    rb_ary_push((VALUE)ary, (VALUE)key);
    return ST_CONTINUE;
}

static int
klh_collect_pair(st_data_t key, st_data_t value, st_data_t hash)
{
    rb_hash_aset((VALUE)hash, (VALUE)key, (VALUE)value);
    return ST_CONTINUE;
}

static VALUE
klh_collect_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;

    st_foreach(op->shard->tbl, RB_TYPE_P(op->value, T_ARRAY) ? klh_collect_key : klh_collect_pair,
               (st_data_t)op->value);
    return Qnil;
}

/* One key's #hash or #eql? reaching back into this map raises NestedLockError
 * rather than deadlocking: the inner call may want a shard this thread does
 * not hold, so unlike LockHash there is no safe reentrant path. */
#define KLH_GUARDED(self, op, body) \
    rs_guarded((self), &(op)->shard->lock, (body), (op), false, \
               "one key is already in hand; two keys together is Ractor::LockHash's job")

/* --- methods -------------------------------------------------------------- */

/*
 *  call-seq:
 *     keylockhash[key] -> value or nil
 *
 *  Reads one key under that key's shard lock.  Unrelated keys do not wait.
 */
static VALUE
klh_aref(VALUE self, VALUE key)
{
    struct klh_op op = { klh_shard_for(self, key), key, Qnil };
    VALUE found = KLH_GUARDED(self, &op, klh_lookup_body);
    return RB_UNDEF_P(found) ? Qnil : found;
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

    op.shard = klh_shard_for(self, key);
    op.key = key;
    op.value = Qnil;
    found = KLH_GUARDED(self, &op, klh_lookup_body);
    if (!RB_UNDEF_P(found)) return found;
    if (rb_block_given_p()) return rb_yield(key);
    if (!RB_UNDEF_P(def)) return def;
    rb_raise(rb_eKeyError, "key not found: %+"PRIsVALUE, key);
}

static VALUE
klh_key_p(VALUE self, VALUE key)
{
    struct klh_op op = { klh_shard_for(self, key), key, Qnil };
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
    op = (struct klh_op){ klh_shard_for(self, key), key, Qnil };
    return KLH_GUARDED(self, &op, klh_store_if_absent_body);
}

static VALUE
klh_update(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();
    key = rs_hash_key(key);     /* may insert it */
    klh_check_shareable(key);
    op = (struct klh_op){ klh_shard_for(self, key), key, Qnil };
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
    op = (struct klh_op){ klh_shard_for(self, key), key, by };
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
    op = (struct klh_op){ klh_shard_for(self, key), key, value };
    return KLH_GUARDED(self, &op, klh_aset_body);
}

/*
 *  call-seq:
 *     keylockhash.delete(key) -> old value or nil
 */
static VALUE
klh_delete(VALUE self, VALUE key)
{
    struct klh_op op = { klh_shard_for(self, key), key, Qnil };
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
        struct klh_op op = { &kh->shards[i], Qnil, ary };
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
        struct klh_op op = { &kh->shards[i], Qnil, hash };
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
