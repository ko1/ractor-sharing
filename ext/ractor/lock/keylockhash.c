#include "lock.h"
#include "ruby/st.h"
#include "oatable.h"

/* Ractor::KeyLockHash - a hash with one lock per key, near enough.
 *
 * Ractor::LockHash is the table lock: one lock over the whole hash, so a
 * section is atomic across its keys and unrelated keys wait for each other.
 * This is the row lock: an update touches one key under one lock, and updates
 * to unrelated keys run in parallel.  Nothing here is atomic across two keys;
 * that is LockHash's job (or Ractor::TVar's).
 *
 * "Near enough": entries live in one open-addressed table, and a value is one
 * VALUE in a slot, so a read is a probe of a flat array and an update is a
 * single atomic word.  Neither takes a lock: reads scale, and so do updates to
 * different keys.  The lock is left for what genuinely needs one writer --
 * inserting a key, growing the table, and #update, whose block must run
 * exactly once and so cannot be retried.
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

static VALUE rb_cRactorKeyLockHash;
static ID id_plus;

struct keylockhash {
    VALUE table;            /* an oa_table object, atomically published */
    struct rs_lock lock;    /* inserts, growth, and the block methods */
};

/* The table a reader should probe.  Held in a local so the object stays
 * reachable even if a writer publishes a new one mid-operation. */
static inline VALUE
klh_table(struct keylockhash *kh)
{
    return OA_LOAD_ACQ(kh->table);
}

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

/* Marking the table object is the whole of it: growing publishes a new table
 * and drops the old, which the ordinary GC then frees.  Nothing is retired by
 * hand and nothing is freed from inside a mark. */
static void
klh_mark(void *ptr)
{
    struct keylockhash *kh = ptr;
    if (kh->table) rb_gc_mark(kh->table);
}

static void
klh_free(void *ptr)
{
    struct keylockhash *kh = ptr;
    rs_lock_destroy(&kh->lock);
    ruby_xfree(kh);
}

static size_t
klh_memsize(const void *ptr)
{
    return sizeof(struct keylockhash);
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
    kh->table = Qfalse;                  /* markable while the table is built */
    rs_lock_init(&kh->lock);
    OA_STORE_REL(kh->table, oa_table_new(0));
    return obj;
}

/* Inserting or growing needs one writer: the caller holds the lock (or nobody
 * else can see the map yet).  Growing builds a new table and publishes it; the
 * old one is simply dropped, and the GC frees it like any other object. */
static void
klh_insert_locked(struct keylockhash *kh, st_index_t hash, VALUE key, VALUE value)
{
    struct oa_table *t = oa_table_ptr(kh->table);

    if (oa_needs_grow(t)) {
        VALUE grown = oa_table_grow(t, t->nslots * 2);
        OA_STORE_REL(kh->table, grown);   /* publish */
        t = oa_table_ptr(grown);
    }
    if (RB_UNLIKELY(!oa_insert(t, hash, key, value))) {
        VALUE grown = oa_table_grow(t, t->nslots * 2);   /* probe run too long */
        OA_STORE_REL(kh->table, grown);
        oa_insert(oa_table_ptr(grown), hash, key, value);
    }
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
    klh_insert_locked(klh_ptr((VALUE)selfv), h, key, value);
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
    struct keylockhash *kh;
    st_index_t hash;
    VALUE key;
    VALUE value;
    VALUE table;            /* keeps the table alive while a block runs */
    struct oa_slot *slot;
};

/* Fills the map + hash for +key+; hash is computed once. */
static struct klh_op
klh_op_make(VALUE self, VALUE key, VALUE value)
{
    st_index_t h = klh_hash(key);
    struct keylockhash *kh = klh_ptr(self);
    struct klh_op op = { kh, h, key, value, klh_table(kh), NULL };
    return op;
}

static VALUE
klh_lookup_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    return oa_get(oa_table_ptr(klh_table(op->kh)), op->hash, op->key);
}

/* store_if_absent: return the value if the key is set, otherwise the block runs
 * ONCE under this key's lock and its result is stored.  The hit path -- the
 * common one in a cache -- never yields, so it costs a read, not an update. */
static VALUE
klh_store_if_absent_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE found = oa_get(oa_table_ptr(op->table = klh_table(op->kh)), op->hash, op->key);
    VALUE computed;

    /* nil counts as absent, like #[] and #update: a real cached value is
     * non-nil, so a nil (missing, or stored nil) means "compute". */
    if (!RB_UNDEF_P(found) && !NIL_P(found)) return found;
    computed = rs_shareable_value(rb_yield(op->key));
    if (NIL_P(computed)) return Qnil;   /* don't cache a nil result */
    klh_insert_locked(op->kh, op->hash, op->key, computed);
    return computed;
}

/* The block runs exactly once, and it is still a compare-and-swap that makes
 * that safe against a lock-free increment: the swap *claims* the slot before
 * the block runs, and it is the claim that is retried, never the block.  Once
 * claimed, the slot is this thread's until it commits, and a writer that finds
 * the claim marker simply backs off. */
static VALUE
klh_update_yield(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE next = rs_shareable_value(rb_yield(op->value));

    oa_commit(oa_table_ptr(op->table), op->hash, op->key, op->slot, next);
    op->slot = NULL;            /* committed: the ensure has nothing to undo */
    return next;
}

static VALUE
klh_update_unclaim(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;

    if (op->slot) {
        oa_unclaim(oa_table_ptr(op->table), op->hash, op->key, op->slot, op->value);
    }
    return Qnil;
}

static VALUE
klh_update_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;

    for (;;) {
        struct oa_slot *s;
        VALUE old, next;

        op->table = klh_table(op->kh);
        s = oa_find(oa_table_ptr(op->table), op->hash, op->key);
        if (s) {
            old = oa_slot_value(s);
            if (old == oa_moved || old == oa_locked) continue;   /* carried, or busy */
            if (!RB_UNDEF_P(old)) {
                if (old == oa_locked) { rb_thread_schedule(); continue; }
                if (!oa_try_claim(s, old)) continue;   /* changed first: claim again */
                op->slot = s;
                op->value = old;
                return rb_ensure(klh_update_yield, ptr, klh_update_unclaim, ptr);
            }
        }
        /* Absent: no other writer can introduce it while we hold the lock. */
        next = rs_shareable_value(rb_yield(Qnil));
        klh_insert_locked(op->kh, op->hash, op->key, next);
        return next;
    }
}

/* (old or 0) + amount, stored under the key's lock.  A missing key counts as
 * zero, the way ActorHash#increment counts it: the tally shape needs no
 * seeding.  Fixnums that stay Fixnums skip the dispatch. */
static VALUE
klh_increment_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    for (;;) {
        struct oa_slot *s;
        VALUE old, next;

        op->table = klh_table(op->kh);
        s = oa_find(oa_table_ptr(op->table), op->hash, op->key);
        old = s ? oa_slot_value(s) : Qundef;
        if (old == oa_moved || old == oa_locked) continue;

        next = rs_fixnum_add(RB_UNDEF_P(old) ? INT2FIX(0) : old, op->value);
        if (RB_UNDEF_P(next)) {
            next = rs_shareable_value(rb_funcall(RB_UNDEF_P(old) ? INT2FIX(0) : old,
                                                 id_plus, 1, op->value));
        }
        if (!RB_UNDEF_P(old)) {
            if (oa_cas_value(s, old, next)) return next;
            continue;
        }
        klh_insert_locked(op->kh, op->hash, op->key, next);
        return next;
    }
}

static VALUE
klh_aset_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    for (;;) {
        struct oa_slot *s;
        VALUE old;

        op->table = klh_table(op->kh);
        s = oa_find(oa_table_ptr(op->table), op->hash, op->key);
        old = s ? oa_slot_value(s) : Qundef;
        if (old == oa_moved || old == oa_locked) continue;
        if (!RB_UNDEF_P(old)) {
            if (oa_cas_value(s, old, op->value)) return op->value;
            continue;
        }
        klh_insert_locked(op->kh, op->hash, op->key, op->value);
        return op->value;
    }
}

static VALUE
klh_delete_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE old = oa_delete(oa_table_ptr(klh_table(op->kh)), op->hash, op->key);
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

/* One key's #hash or #eql? reaching back into this map raises NestedLockError
 * rather than deadlocking: the inner call may want the lock this thread
 * already holds, so unlike LockHash there is no safe reentrant path. */
/* Marks the thread without locking: the body synchronises per entry with a
 * compare-and-swap, but "one key at a time" is the design, so a second key
 * inside the block is still refused. */
#define KLH_MARKED(self, op, body) \
    rs_guarded((self), NULL, (body), (op), false, \
               "one key is already in hand; two keys together is Ractor::LockHash's job")

#define KLH_GUARDED(self, op, body) \
    rs_guarded((self), &(op)->kh->lock, (body), (op), false, \
               "one key is already in hand; two keys together is Ractor::LockHash's job")

/* --- methods -------------------------------------------------------------- */

/* A read whose key is an immediate takes NO lock at all: see rcu_lookup.
 * Returns Qundef for a non-immediate key so the caller falls back to the
 * guarded (locked) path, where a String key's #eql? may run Ruby. */
static VALUE
klh_fast_lookup(VALUE self, VALUE key)
{
    st_index_t h;

    if (!SPECIAL_CONST_P(key)) return Qundef;
    /* Nesting is still refused: inside any update, a read raises. */
    if (RB_UNLIKELY(!NIL_P(rs_held(rb_thread_current())))) return Qundef;

    h = klh_hash(key);
    /* No lock: probe the flat array and read the value where it lies.  An
     * immediate key compares by identity, so this runs no Ruby and writes
     * nothing shared -- readers never invalidate each other's cache line. */
    return oa_lookup(oa_table_ptr(klh_table(klh_ptr(self))), h, key);
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
 *  The value at +key+ if it is set to a non-nil value; otherwise the block runs
 *  once, under that key's lock, and its result is stored and returned -- the
 *  per-key analogue of Ractor.store_if_absent.  A nil value counts as absent
 *  (as with #[] and #update), so nil is never cached: the block runs again next
 *  time.  This is the memoize / cache primitive: simultaneous misses on one key
 *  compute once and the rest read the answer, and a hit never runs the block.
 */
static VALUE
klh_store_if_absent(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();

    /* Fast path: a hit on an immediate key is a lock-free read, so the common
     * case in a cache -- the value is already there -- never takes the lock or
     * runs the block.  A miss falls through to compute-and-store under the lock,
     * where a stampede still computes once. */
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) {
        st_index_t h = klh_hash(key);
        VALUE found = oa_lookup(oa_table_ptr(klh_table(klh_ptr(self))), h, key);
        if (!RB_UNDEF_P(found) && !NIL_P(found)) return found;
    }

    key = rs_hash_key(key);
    klh_check_shareable(key);   /* may insert it */
    op = klh_op_make(self, key, Qnil);
    return KLH_GUARDED(self, &op, klh_store_if_absent_body);
}

/* Synchronising on the entry itself: claim the slot with a compare-and-swap and
 * the block runs exactly once, with no lock and no interference from another
 * key.  Qundef means the entry could not be taken this way -- it is absent, or
 * being carried by a grow -- and the caller falls back to the locked path. */
static VALUE
klh_update_claim_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;

    for (;;) {
        VALUE old = oa_slot_value(op->slot);

        if (RB_UNDEF_P(old) || old == oa_moved) return Qundef;   /* absent, or carried */
        if (old == oa_locked) {          /* another update owns this very key */
            rb_thread_schedule();        /* it is serialised anyway; let it finish */
            continue;
        }
        if (!oa_try_claim(op->slot, old)) continue;   /* changed first: claim again */
        op->value = old;
        return rb_ensure(klh_update_yield, ptr, klh_update_unclaim, ptr);
    }
}

static VALUE
klh_update(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();
    key = rs_hash_key(key);     /* may insert it */
    klh_check_shareable(key);
    op = klh_op_make(self, key, Qnil);

    /* A key that is already here is synchronised on its own slot, so updates to
     * unrelated keys never wait for each other.  The lock is only for what
     * changes the table's shape: introducing a key, and growing. */
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) {
        op.slot = oa_find_imm(oa_table_ptr(op.table), op.hash, key);
        if (op.slot) {
            VALUE v = KLH_MARKED(self, &op, klh_update_claim_body);
            if (!RB_UNDEF_P(v)) return v;
            op.slot = NULL;
        }
    }
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

    /* A counter is the case this class is asked for most, and it needs no
     * block: read the slot, add, and swap the sum in with a compare-and-swap.
     * Losing the race means another Ractor got there first, so the retry adds
     * to its value -- no update is lost, and no lock is taken. */
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) {
        st_index_t h = klh_hash(key);
        struct oa_slot *slot = oa_find_imm(oa_table_ptr(klh_table(klh_ptr(self))), h, key);
        if (slot) {
            for (;;) {
                VALUE old = oa_slot_value(slot);
                VALUE next;
                if (RB_UNDEF_P(old) || old == oa_moved || old == oa_locked) break;
                next = rs_fixnum_add(old, by);
                if (RB_UNDEF_P(next)) break;          /* not two Fixnums */
                if (oa_cas_value(slot, old, next)) return next;
            }
        }
    }
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

    /* The key is already here: the value is one VALUE in a slot, so replacing
     * it is a single atomic store.  No lock, and nothing left behind. */
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) {
        st_index_t h = klh_hash(key);
        struct oa_slot *slot = oa_find_imm(oa_table_ptr(klh_table(klh_ptr(self))), h, key);
        if (slot) {
            for (;;) {
                VALUE old = oa_slot_value(slot);
                if (RB_UNDEF_P(old) || old == oa_moved || old == oa_locked) break;
                if (oa_cas_value(slot, old, value)) return value;
            }
        }
    }
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
/* The table object is held in a local, so a writer that publishes a new one
 * mid-walk cannot take this one out from under us: it stays reachable. */
static VALUE
klh_keys(VALUE self)
{
    VALUE ary = rb_ary_new();
    VALUE tbl = klh_table(klh_ptr(self));

    oa_foreach(oa_table_ptr(tbl), klh_collect_key, (void *)ary);
    return ary;
}

static VALUE
klh_to_h(VALUE self)
{
    VALUE hash = rb_hash_new();
    VALUE tbl = klh_table(klh_ptr(self));

    oa_foreach(oa_table_ptr(tbl), klh_collect_pair, (void *)hash);
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
