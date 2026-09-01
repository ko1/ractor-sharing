#include "lock.h"

/* Ractor::LockHash - a Hash several Ractors can share.
 *
 * The Hash itself never leaves: #synchronize yields the LockHash, not the Hash
 * inside it, so nothing can keep a reference and write to it later or from
 * another Ractor.  Every write goes through #synchronize, which is a critical
 * section over this one hash: whatever it changes, other Ractors see all of it
 * or none of it.
 *
 * That atomicity costs parallelism.  One lock covers the whole hash, so writes
 * to unrelated keys wait for each other; a hash that has to be written to
 * constantly wants one Ractor::LockVar per key instead, and atomicity across
 * separate objects wants Ractor::TVar.
 */

static VALUE rb_cRactorLockHash;
static ID id_keys, id_zero_p;

struct lockhash {
    VALUE hash;                 /* the real Hash; hidden from everyone */
    struct rs_lock lock;
};

/* The hash is deliberately *not* marked from here.  Ractor.make_shareable walks
 * a T_DATA through its mark function and freezes everything it finds, which is
 * exactly what must not happen to the hash we mean to keep mutating, so it is
 * kept alive as a GC root of its own instead. */
static void
lockhash_free(void *ptr)
{
    struct lockhash *lh = ptr;
    rb_gc_unregister_address(&lh->hash);
    rs_lock_destroy(&lh->lock);
    ruby_xfree(lh);
}

static size_t
lockhash_memsize(const void *ptr)
{
    return sizeof(struct lockhash);
}

static const rb_data_type_t lockhash_data_type = {
    "Ractor::LockHash",
    {NULL, lockhash_free, lockhash_memsize, NULL},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE
};

static struct lockhash *
lockhash_ptr(VALUE self)
{
    struct lockhash *lh;
    TypedData_Get_Struct(self, struct lockhash, &lockhash_data_type, lh);
    return lh;
}

static void
lockhash_check_shareable(VALUE val)
{
    if (RB_UNLIKELY(!rb_ractor_shareable_p(val))) {
        rb_raise(rb_eArgError, "only shareable object are allowed");
    }
}

/* Writes are only allowed from inside this hash's own #synchronize.  Outside it
 * the method is not callable at all, the way a private method is not. */
static void
lockhash_check_writable(VALUE self, const char *mid)
{
    VALUE held = rs_held(rb_thread_current());

    if (held == self) return;

    if (NIL_P(held)) {
        rb_raise(rb_eNoMethodError,
                 "'%s' is only allowed inside %"PRIsVALUE"#synchronize",
                 mid, rb_obj_class(self));
    }
    rb_raise(rb_eRactorNestedLock,
             "already inside another %"PRIsVALUE"; "
             "use Ractor::TVar to change several of them together",
             rb_obj_class(held));
}

static VALUE
lockhash_alloc(VALUE klass)
{
    struct lockhash *lh;
    VALUE obj = TypedData_Make_Struct(klass, struct lockhash, &lockhash_data_type, lh);
    lh->hash = rb_hash_new();
    rb_gc_register_address(&lh->hash);
    rs_lock_init(&lh->lock);
    return obj;
}

static int
lockhash_copy_pair(VALUE key, VALUE value, VALUE dest)
{
    lockhash_check_shareable(key);
    lockhash_check_shareable(value);
    rb_hash_aset(dest, key, value);
    return ST_CONTINUE;
}

static VALUE
lockhash_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE init = Qnil;

    rb_scan_args(argc, argv, "01", &init);
    if (!NIL_P(init)) {
        init = rb_convert_type(init, T_HASH, "Hash", "to_hash");
        rb_hash_foreach(init, lockhash_copy_pair, lockhash_ptr(self)->hash);
    }
    /* The LockHash never changes; the hash it guards does. */
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
    return self;
}

/* --- guarded bodies ------------------------------------------------------- */

struct lockhash_op {
    VALUE key;
    VALUE value;
    int argc;
};

static VALUE
lockhash_aref_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockhash_op *op = arg->data;
    return rb_hash_aref(lockhash_ptr(arg->self)->hash, op->key);
}

static VALUE
lockhash_fetch_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockhash_op *op = arg->data;
    VALUE found = rb_hash_lookup2(lockhash_ptr(arg->self)->hash, op->key, Qundef);

    if (!RB_UNDEF_P(found)) return found;
    if (op->argc > 1) return op->value;
    if (rb_block_given_p()) return rb_yield(op->key);
    rb_raise(rb_eKeyError, "key not found: %+"PRIsVALUE, op->key);
}

static VALUE
lockhash_key_p_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockhash_op *op = arg->data;
    return RB_UNDEF_P(rb_hash_lookup2(lockhash_ptr(arg->self)->hash, op->key, Qundef))
           ? Qfalse : Qtrue;
}

static VALUE
lockhash_size_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return rb_hash_size(lockhash_ptr(arg->self)->hash);
}

static VALUE
lockhash_keys_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return rb_ractor_make_shareable(rb_funcall(lockhash_ptr(arg->self)->hash, id_keys, 0));
}

static VALUE
lockhash_to_h_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return rb_ractor_make_shareable(rb_obj_dup(lockhash_ptr(arg->self)->hash));
}

static VALUE
lockhash_sync_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    rs_held_set(arg->thread, arg->self);
    return rb_yield(arg->self);
}

/* --- reads ---------------------------------------------------------------- */

#define LOCKHASH_READ(self, body, op) \
    rs_guarded((self), &lockhash_ptr(self)->lock, (body), (op), true, "")

/*
 *  call-seq:
 *     lockhash[key] -> value
 *
 *  Reads one entry under the lock, so it never sees a #synchronize half done.
 */
static VALUE
lockhash_aref(VALUE self, VALUE key)
{
    struct lockhash_op op = {key, Qnil, 1};
    return LOCKHASH_READ(self, lockhash_aref_body, &op);
}

static VALUE
lockhash_fetch(int argc, VALUE *argv, VALUE self)
{
    struct lockhash_op op = {Qnil, Qnil, argc};
    rb_scan_args(argc, argv, "11", &op.key, &op.value);
    return LOCKHASH_READ(self, lockhash_fetch_body, &op);
}

static VALUE
lockhash_key_p(VALUE self, VALUE key)
{
    struct lockhash_op op = {key, Qnil, 1};
    return LOCKHASH_READ(self, lockhash_key_p_body, &op);
}

static VALUE
lockhash_size(VALUE self)
{
    return LOCKHASH_READ(self, lockhash_size_body, NULL);
}

static VALUE
lockhash_empty_p(VALUE self)
{
    return RTEST(rb_funcall(lockhash_size(self), id_zero_p, 0)) ? Qtrue : Qfalse;
}

/*
 *  call-seq:
 *     lockhash.keys -> array
 *     lockhash.to_h -> hash
 *
 *  A snapshot taken under the lock, frozen and shareable, of the whole hash as
 *  it was at one moment.
 */
static VALUE
lockhash_keys(VALUE self)
{
    return LOCKHASH_READ(self, lockhash_keys_body, NULL);
}

static VALUE
lockhash_to_h(VALUE self)
{
    return LOCKHASH_READ(self, lockhash_to_h_body, NULL);
}

/* --- writes: only from inside #synchronize -------------------------------- */

/*
 *  call-seq:
 *     lockhash[key] = value -> value
 *
 *  Stores one entry.  Only allowed inside this hash's #synchronize, so that
 *  reading an entry and writing it back is one step and not two.
 */
static VALUE
lockhash_aset(VALUE self, VALUE key, VALUE value)
{
    lockhash_check_writable(self, "[]=");
    lockhash_check_shareable(key);
    lockhash_check_shareable(value);
    rb_hash_aset(lockhash_ptr(self)->hash, key, value);
    return value;
}

static VALUE
lockhash_delete(VALUE self, VALUE key)
{
    lockhash_check_writable(self, "delete");
    return rb_hash_delete(lockhash_ptr(self)->hash, key);
}

static VALUE
lockhash_clear(VALUE self)
{
    lockhash_check_writable(self, "clear");
    rb_hash_clear(lockhash_ptr(self)->hash);
    return self;
}

/*
 *  call-seq:
 *     lockhash.synchronize {|lockhash| ... } -> object
 *
 *  Runs the block holding this hash, and returns the block's value.  Everything
 *  it changes becomes visible together.  The block is handed the LockHash
 *  itself, never the Hash inside it, so no reference to the state escapes.
 *
 *      board.synchronize {|b| b[:me] = score; b.delete(:stale) }
 *
 *  Keep it short: every reader and writer of this hash waits for it.
 */
static VALUE
lockhash_synchronize(VALUE self)
{
    rb_need_block();
    return rs_guarded(self, &lockhash_ptr(self)->lock, lockhash_sync_body, NULL, true, "");
}

static VALUE
lockhash_inspect(VALUE self)
{
    return rb_sprintf("#<%"PRIsVALUE" %+"PRIsVALUE">",
                      rb_obj_class(self), lockhash_ptr(self)->hash);
}

void
Init_lockhash_class(void)
{
    id_keys = rb_intern("keys");
    id_zero_p = rb_intern("zero?");

    rb_cRactorLockHash = rb_define_class_under(rb_cRactor, "LockHash", rb_cObject);
    rb_define_alloc_func(rb_cRactorLockHash, lockhash_alloc);
    rb_define_method(rb_cRactorLockHash, "initialize", lockhash_initialize, -1);

    rb_define_method(rb_cRactorLockHash, "[]", lockhash_aref, 1);
    rb_define_method(rb_cRactorLockHash, "fetch", lockhash_fetch, -1);
    rb_define_method(rb_cRactorLockHash, "key?", lockhash_key_p, 1);
    rb_define_method(rb_cRactorLockHash, "size", lockhash_size, 0);
    rb_define_method(rb_cRactorLockHash, "empty?", lockhash_empty_p, 0);
    rb_define_method(rb_cRactorLockHash, "keys", lockhash_keys, 0);
    rb_define_method(rb_cRactorLockHash, "to_h", lockhash_to_h, 0);

    rb_define_method(rb_cRactorLockHash, "[]=", lockhash_aset, 2);
    rb_define_method(rb_cRactorLockHash, "delete", lockhash_delete, 1);
    rb_define_method(rb_cRactorLockHash, "clear", lockhash_clear, 0);
    rb_define_method(rb_cRactorLockHash, "synchronize", lockhash_synchronize, 0);

    rb_define_method(rb_cRactorLockHash, "inspect", lockhash_inspect, 0);

    rb_define_const(rb_cRactorLockHash, "NestedLockError", rb_eRactorNestedLock);
}
