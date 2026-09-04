#include "lock.h"
#include "ruby/st.h"
#include "oatable.h"

/* Ractor::KeyLockHash
 *
 * The index and the records deliberately have different lifetimes:
 *
 *   bins[] -> append-only entries
 *
 * A resize builds a complete bins generation and atomically publishes it.
 * Entries never move, so an update block may claim one, run for an arbitrary
 * time without the structural lock, and commit after any number of resizes.
 * Contenders for that entry park on waiter-owned Ractor::Ports.
 */

static VALUE rb_cRactorKeyLockHash;
static ID id_plus;

struct keylockhash {
    VALUE bins;                /* current bins generation, atomically published */
    struct oa_store store;     /* append-only stable entries + transient waiters */
    struct rs_lock lock;       /* entry insertion and bins replacement */
};

static inline VALUE
klh_bins(struct keylockhash *kh)
{
    return OA_LOAD_ACQ(kh->bins);
}

/* Immediate keys are their own identity hash; other keys may invoke Ruby. */
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
    VALUE bins = klh_bins(kh);
    if (bins) rb_gc_mark(bins);
    oa_store_mark(&kh->store);
}

static void
klh_free(void *ptr)
{
    struct keylockhash *kh = ptr;
    oa_store_destroy(&kh->store);
    rs_lock_destroy(&kh->lock);
    ruby_xfree(kh);
}

static size_t
klh_memsize(const void *ptr)
{
    const struct keylockhash *kh = ptr;
    return sizeof(*kh) + oa_store_memsize(&kh->store);
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
klh_check_shareable(VALUE value)
{
    if (RB_UNLIKELY(!rb_ractor_shareable_p(value))) {
        rb_raise(rb_eArgError, "only shareable object are allowed");
    }
}

static VALUE
klh_alloc(VALUE klass)
{
    struct keylockhash *kh;
    VALUE obj = TypedData_Make_Struct(klass, struct keylockhash, &klh_data_type, kh);
    kh->bins = Qfalse;
    oa_store_init(&kh->store);
    rs_lock_init(&kh->lock);
    OA_STORE_REL(kh->bins, oa_bins_new(0));
    return obj;
}

/* Caller holds the structural lock, or the object is not visible yet. */
static struct oa_bins *
klh_room_for_entry(struct keylockhash *kh)
{
    VALUE bins_obj = klh_bins(kh);
    struct oa_bins *bins = oa_bins_ptr(bins_obj);

    if (oa_bins_needs_grow(bins)) {
        VALUE grown = oa_bins_grow(bins, 0); /* zero means twice the old size */
        OA_STORE_REL(kh->bins, grown);
        bins = oa_bins_ptr(grown);
    }
    return bins;
}

static struct oa_entry *
klh_insert_locked(struct keylockhash *kh, st_index_t hash, VALUE key, VALUE value)
{
    return oa_insert(&kh->store, klh_room_for_entry(kh), hash, key, value);
}

static int
klh_copy_pair(VALUE key, VALUE value, VALUE selfv)
{
    struct keylockhash *kh = klh_ptr(selfv);
    key = rs_hash_key(key);
    klh_check_shareable(key);
    value = rs_shareable_value(value);
    klh_insert_locked(kh, klh_hash(key), key, value);
    return ST_CONTINUE;
}

static VALUE
klh_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE init = Qnil;
    rb_check_frozen(self);
    rb_scan_args(argc, argv, "01", &init);
    if (!NIL_P(init)) {
        Check_Type(init, T_HASH);
        rb_hash_foreach(init, klh_copy_pair, self);
    }
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
    return self;
}

/* --- one-operation state ------------------------------------------------- */

enum klh_claim_kind {
    KLH_UPDATE,
    KLH_STORE_IF_ABSENT,
    KLH_INCREMENT
};

struct klh_op {
    struct keylockhash *kh;
    st_index_t hash;
    VALUE key;
    VALUE value;
    VALUE old;
    struct oa_entry *entry;
    size_t claim_id;
    bool claimed;
    bool inserted;
    enum klh_claim_kind kind;
};

static struct klh_op
klh_op_make(VALUE self, VALUE key, VALUE value)
{
    struct klh_op op = {
        klh_ptr(self), klh_hash(key), key, value, Qundef,
        NULL, 0, false, false, KLH_UPDATE
    };
    return op;
}

#define KLH_MARKED(self, op, body) \
    rs_guarded((self), NULL, (body), (op), false, \
               "one key is already in hand; two keys together is Ractor::LockHash's job")

#define KLH_GUARDED(self, op, body) \
    rs_guarded((self), &(op)->kh->lock, (body), (op), false, \
               "one key is already in hand; two keys together is Ractor::LockHash's job")

static VALUE
klh_resolve_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    op->entry = oa_find(oa_bins_ptr(klh_bins(op->kh)), op->hash, op->key);
    return Qnil;
}

/* Resolve to a stable entry.  Only immediate keys can probe without running
 * Ruby; every other key is compared under the structural guard. */
static void
klh_resolve(VALUE self, struct klh_op *op)
{
    if (SPECIAL_CONST_P(op->key) && NIL_P(rs_held(rb_thread_current()))) {
        op->entry = oa_find_imm(oa_bins_ptr(klh_bins(op->kh)), op->hash, op->key);
    }
    else {
        KLH_GUARDED(self, op, klh_resolve_body);
    }
}

/* Recheck absence under the structural lock and publish an already-claimed
 * entry.  The block runs only after this guard has been released. */
static VALUE
klh_claim_missing_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    struct oa_bins *bins = oa_bins_ptr(klh_bins(op->kh));

    op->entry = oa_find(bins, op->hash, op->key);
    if (!op->entry) {
        bins = klh_room_for_entry(op->kh);
        op->entry = oa_insert_claimed(&op->kh->store, bins, op->hash, op->key,
                                      Qundef, &op->claim_id);
        op->old = Qundef;
        op->claimed = true;
    }
    return Qnil;
}

static VALUE
klh_insert_value_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    struct oa_bins *bins = oa_bins_ptr(klh_bins(op->kh));

    op->entry = oa_find(bins, op->hash, op->key);
    if (!op->entry) {
        op->entry = klh_insert_locked(op->kh, op->hash, op->key, op->value);
        op->inserted = true;
    }
    return Qnil;
}

/* Obtain a claim, inserting the stable entry if this key has never appeared.
 * A busy entry is waited on without holding the structural lock. */
static void
klh_claim(VALUE self, struct klh_op *op)
{
    for (;;) {
        VALUE old;

        klh_resolve(self, op);
        if (!op->entry) {
            KLH_GUARDED(self, op, klh_claim_missing_body);
            if (op->claimed) return;
            continue;
        }

        old = oa_entry_raw(op->entry);
        if (oa_busy_value(old)) {
            oa_wait(&op->kh->store, op->entry);
            continue;
        }
        if (oa_try_claim(op->entry, old, &op->claim_id)) {
            op->old = old;
            op->claimed = true;
            return;
        }
    }
}

static VALUE
klh_claim_ensure(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    if (op->claimed) {
        bool wake = oa_finish_claim(op->entry, op->claim_id, op->old);
        op->claimed = false;
        if (wake) oa_wake_claim(&op->kh->store, op->entry, op->claim_id);
    }
    return Qnil;
}

static VALUE
klh_claim_run(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    VALUE next;

    switch (op->kind) {
      case KLH_STORE_IF_ABSENT:
        next = rs_shareable_value(rb_yield(op->key));
        if (NIL_P(next)) {
            bool wake = oa_finish_claim(op->entry, op->claim_id, op->old);
            op->claimed = false;
            if (wake) oa_wake_claim(&op->kh->store, op->entry, op->claim_id);
            return Qnil;
        }
        break;
      case KLH_INCREMENT: {
        VALUE old = RB_UNDEF_P(op->old) ? INT2FIX(0) : op->old;
        next = rs_fixnum_add(old, op->value);
        if (RB_UNDEF_P(next)) {
            next = rs_shareable_value(rb_funcall(old, id_plus, 1, op->value));
        }
        break;
      }
      default:
        next = rs_shareable_value(rb_yield(RB_UNDEF_P(op->old) ? Qnil : op->old));
        break;
    }

    bool wake = oa_finish_claim(op->entry, op->claim_id, next);
    op->claimed = false;
    if (wake) oa_wake_claim(&op->kh->store, op->entry, op->claim_id);
    return next;
}

static VALUE
klh_run_claim(VALUE ptr)
{
    return rb_ensure(klh_claim_run, ptr, klh_claim_ensure, ptr);
}

/* --- reads --------------------------------------------------------------- */

static VALUE
klh_fast_lookup(VALUE self, VALUE key)
{
    st_index_t hash;

    if (!SPECIAL_CONST_P(key)) return Qundef;
    if (RB_UNLIKELY(!NIL_P(rs_held(rb_thread_current())))) return Qundef;
    hash = klh_hash(key);
    /* No Ruby and no safepoint: an old bins generation cannot be reclaimed
     * until this lookup has returned. */
    return oa_lookup(oa_bins_ptr(klh_bins(klh_ptr(self))), hash, key);
}

static VALUE
klh_lookup_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct klh_op *op = arg->data;
    return oa_get(oa_bins_ptr(klh_bins(op->kh)), op->hash, op->key);
}

static VALUE
klh_aref(VALUE self, VALUE key)
{
    VALUE found = klh_fast_lookup(self, key);
    if (!RB_UNDEF_P(found)) return found;
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) return Qnil;
    {
        struct klh_op op = klh_op_make(self, key, Qnil);
        found = KLH_GUARDED(self, &op, klh_lookup_body);
        return RB_UNDEF_P(found) ? Qnil : found;
    }
}

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
    VALUE found = klh_fast_lookup(self, key);
    if (!RB_UNDEF_P(found)) return Qtrue;
    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) return Qfalse;
    {
        struct klh_op op = klh_op_make(self, key, Qnil);
        return RB_UNDEF_P(KLH_GUARDED(self, &op, klh_lookup_body)) ? Qfalse : Qtrue;
    }
}

/* --- block operations ---------------------------------------------------- */

static VALUE
klh_update(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();
    key = rs_hash_key(key);
    klh_check_shareable(key);
    op = klh_op_make(self, key, Qnil);
    op.kind = KLH_UPDATE;
    klh_claim(self, &op);
    return KLH_MARKED(self, &op, klh_run_claim);
}

static VALUE
klh_store_if_absent(VALUE self, VALUE key)
{
    struct klh_op op;
    rb_need_block();

    if (SPECIAL_CONST_P(key) && NIL_P(rs_held(rb_thread_current()))) {
        VALUE found = klh_fast_lookup(self, key);
        if (!RB_UNDEF_P(found) && !NIL_P(found)) return found;
    }

    key = rs_hash_key(key);
    klh_check_shareable(key);
    op = klh_op_make(self, key, Qnil);
    op.kind = KLH_STORE_IF_ABSENT;

    for (;;) {
        VALUE old;
        klh_resolve(self, &op);
        if (!op.entry) {
            KLH_GUARDED(self, &op, klh_claim_missing_body);
            if (op.claimed) break;
            continue;
        }
        old = oa_entry_raw(op.entry);
        if (oa_busy_value(old)) {
            oa_wait(&op.kh->store, op.entry);
            continue;
        }
        if (!RB_UNDEF_P(old) && !NIL_P(old)) return old;
        if (oa_try_claim(op.entry, old, &op.claim_id)) {
            op.old = old;
            op.claimed = true;
            break;
        }
    }
    return KLH_MARKED(self, &op, klh_run_claim);
}

static VALUE
klh_increment(int argc, VALUE *argv, VALUE self)
{
    VALUE key, by;
    struct klh_op op;

    rb_check_arity(argc, 1, 2);
    key = rs_hash_key(argv[0]);
    klh_check_shareable(key);
    by = argc < 2 ? INT2FIX(1) : argv[1];
    op = klh_op_make(self, key, by);
    op.kind = KLH_INCREMENT;

    for (;;) {
        VALUE old, next;

        klh_resolve(self, &op);
        if (!op.entry) {
            KLH_GUARDED(self, &op, klh_claim_missing_body);
            if (op.claimed) break;
            continue;
        }
        old = oa_entry_raw(op.entry);
        if (oa_busy_value(old)) {
            oa_wait(&op.kh->store, op.entry);
            continue;
        }
        next = RB_UNDEF_P(old) ? Qundef : rs_fixnum_add(old, by);
        if (!RB_UNDEF_P(next)) {
            if (oa_entry_cas(op.entry, old, next)) return next;
            continue;
        }
        if (oa_try_claim(op.entry, old, &op.claim_id)) {
            op.old = old;
            op.claimed = true;
            break;
        }
    }
    return KLH_MARKED(self, &op, klh_run_claim);
}

/* --- plain writes -------------------------------------------------------- */

static VALUE
klh_aset(VALUE self, VALUE key, VALUE value)
{
    struct klh_op op;

    key = rs_hash_key(key);
    klh_check_shareable(key);
    value = rs_shareable_value(value);
    op = klh_op_make(self, key, value);

    for (;;) {
        VALUE old;
        klh_resolve(self, &op);
        if (!op.entry) {
            op.inserted = false;
            KLH_GUARDED(self, &op, klh_insert_value_body);
            if (op.inserted) return value;
            continue;
        }
        old = oa_entry_raw(op.entry);
        if (oa_busy_value(old)) {
            oa_wait(&op.kh->store, op.entry);
            continue;
        }
        if (oa_entry_cas(op.entry, old, value)) return value;
    }
}

static VALUE
klh_delete(VALUE self, VALUE key)
{
    struct klh_op op = klh_op_make(self, key, Qnil);

    for (;;) {
        VALUE old;
        klh_resolve(self, &op);
        if (!op.entry) return Qnil;
        old = oa_entry_raw(op.entry);
        if (oa_busy_value(old)) {
            oa_wait(&op.kh->store, op.entry);
            continue;
        }
        if (RB_UNDEF_P(old)) return Qnil;
        if (oa_entry_cas(op.entry, old, Qundef)) return old;
    }
}

/* --- copies and inspection ---------------------------------------------- */

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
    oa_foreach(oa_bins_ptr(klh_bins(op->kh)),
               RB_TYPE_P(op->value, T_ARRAY) ? klh_collect_key : klh_collect_pair,
               (void *)op->value);
    return op->value;
}

static VALUE
klh_keys(VALUE self)
{
    VALUE ary = rb_ary_new();
    struct klh_op op = klh_op_make(self, Qnil, ary);
    return KLH_GUARDED(self, &op, klh_collect_body);
}

static VALUE
klh_to_h(VALUE self)
{
    VALUE hash = rb_hash_new();
    struct klh_op op = klh_op_make(self, Qnil, hash);
    return KLH_GUARDED(self, &op, klh_collect_body);
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
