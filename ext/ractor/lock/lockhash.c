#include "lock.h"
#include "ruby/st.h"

/* Ractor::LockHash - a Hash several Ractors can share.
 *
 * The entries live in an st_table, not in a Ruby Hash.  A Hash would be an
 * unshareable object belonging to whichever Ractor built it, and every other
 * Ractor writing into it would be touching another Ractor's object -- a
 * containment violation, and an edge from a shareable object to an unshareable
 * one that only the VM can record.  Keys and values are shareable, so with a C
 * table there is no such object at all: the container belongs to nobody.
 *
 * Nothing escapes either: #synchronize yields the LockHash, never the entries.
 * Every write goes through it, and it is a critical section over this one hash:
 * whatever it changes, other Ractors see all of it or none of it.
 *
 * That atomicity costs parallelism.  One lock covers the whole hash, so writes
 * to unrelated keys wait for each other; a hash that has to be written to
 * constantly wants one Ractor::LockVar per key instead, and atomicity across
 * separate objects wants Ractor::TVar.
 */

static VALUE rb_cRactorLockHash;

struct lockhash {
    st_table *tbl;              /* shareable VALUE => shareable VALUE */
    struct rs_lock lock;
};

/* Keys are shareable, so they are frozen and their hash is stable. */
static st_index_t
lockhash_key_hash(st_data_t key)
{
    return (st_index_t)NUM2LONG(rb_hash((VALUE)key));
}

static int
lockhash_key_cmp(st_data_t a, st_data_t b)
{
    return rb_eql((VALUE)a, (VALUE)b) ? 0 : 1;
}

static const struct st_hash_type lockhash_type = {
    lockhash_key_cmp,
    lockhash_key_hash,
};

static int
lockhash_mark_i(st_data_t key, st_data_t value, st_data_t arg)
{
    rb_gc_mark((VALUE)key);
    rb_gc_mark((VALUE)value);
    return ST_CONTINUE;
}

/* Everything in the table is shareable already, so Ractor.make_shareable
 * walking in here through the mark function has nothing left to freeze. */
static void
lockhash_mark(void *ptr)
{
    st_foreach(((struct lockhash *)ptr)->tbl, lockhash_mark_i, 0);
}

static void
lockhash_free(void *ptr)
{
    struct lockhash *lh = ptr;
    st_free_table(lh->tbl);
    rs_lock_destroy(&lh->lock);
    ruby_xfree(lh);
}

static size_t
lockhash_memsize(const void *ptr)
{
    const struct lockhash *lh = ptr;
    return sizeof(struct lockhash) + st_memsize(lh->tbl);
}

static const rb_data_type_t lockhash_data_type = {
    "Ractor::LockHash",
    {lockhash_mark, lockhash_free, lockhash_memsize, NULL},
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
    lh->tbl = st_init_table(&lockhash_type);
    rs_lock_init(&lh->lock);
    return obj;
}

static int
lockhash_copy_pair(VALUE key, VALUE value, VALUE dest)
{
    lockhash_check_shareable(key);
    lockhash_check_shareable(value);
    st_insert(((struct lockhash *)dest)->tbl, (st_data_t)key, (st_data_t)value);
    return ST_CONTINUE;
}

static VALUE
lockhash_initialize(int argc, VALUE *argv, VALUE self)
{
    rb_check_frozen(self);   /* send(:initialize) again would write past the lock */
    VALUE init = Qnil;

    rb_scan_args(argc, argv, "01", &init);
    if (!NIL_P(init)) {
        init = rb_convert_type(init, T_HASH, "Hash", "to_hash");
        rb_hash_foreach(init, lockhash_copy_pair, (VALUE)lockhash_ptr(self));
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

/* Qundef when absent. */
static VALUE
lockhash_lookup(VALUE self, VALUE key)
{
    st_data_t found;
    return st_lookup(lockhash_ptr(self)->tbl, (st_data_t)key, &found) ? (VALUE)found : Qundef;
}

static VALUE
lockhash_aref_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockhash_op *op = arg->data;
    VALUE found = lockhash_lookup(arg->self, op->key);
    return RB_UNDEF_P(found) ? Qnil : found;
}

static VALUE
lockhash_fetch_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockhash_op *op = arg->data;
    return lockhash_lookup(arg->self, op->key);
}

static VALUE
lockhash_key_p_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockhash_op *op = arg->data;
    return RB_UNDEF_P(lockhash_lookup(arg->self, op->key)) ? Qfalse : Qtrue;
}

static int
lockhash_collect_key(st_data_t key, st_data_t value, st_data_t ary)
{
    rb_ary_push((VALUE)ary, (VALUE)key);
    return ST_CONTINUE;
}

static int
lockhash_collect_pair(st_data_t key, st_data_t value, st_data_t hash)
{
    rb_hash_aset((VALUE)hash, (VALUE)key, (VALUE)value);
    return ST_CONTINUE;
}

/* A Hash of the entries as they are now, owned by the calling Ractor. */
static VALUE
lockhash_snapshot(VALUE self)
{
    VALUE hash = rb_hash_new();
    st_foreach(lockhash_ptr(self)->tbl, lockhash_collect_pair, (st_data_t)hash);
    return hash;
}

static VALUE
lockhash_keys_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    VALUE keys = rb_ary_new_capa(lockhash_ptr(arg->self)->tbl->num_entries);
    st_foreach(lockhash_ptr(arg->self)->tbl, lockhash_collect_key, (st_data_t)keys);
    return keys;
}

static VALUE
lockhash_to_h_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return lockhash_snapshot(arg->self);
}

static VALUE
lockhash_sync_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return rb_yield(arg->self);   /* rs_guarded has marked the lock held */
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
    VALUE found;

    rb_scan_args(argc, argv, "11", &op.key, &op.value);
    found = LOCKHASH_READ(self, lockhash_fetch_body, &op);
    if (!RB_UNDEF_P(found)) return found;

    /* The default runs with the lock released.  Held, a block that touched this
     * hash again would wait for a lock its own frame is holding. */
    if (rb_block_given_p()) return rb_yield(op.key);
    if (argc > 1) return op.value;
    rb_raise(rb_eKeyError, "key not found: %+"PRIsVALUE, op.key);
}

static VALUE
lockhash_key_p(VALUE self, VALUE key)
{
    struct lockhash_op op = {key, Qnil, 1};
    return LOCKHASH_READ(self, lockhash_key_p_body, &op);
}

/*
 *  call-seq:
 *     lockhash.keys -> array
 *     lockhash.to_h -> hash
 *
 *  A snapshot taken under the lock of the whole hash as it was at one moment:
 *  a plain mutable copy, the caller's own.  Not frozen -- freezing protected
 *  nothing (the LockHash never sees the copy again) and only stopped the
 *  caller reshaping it.  Everything inside is shareable, so make_shareable is
 *  one cheap call away when it has to cross to another Ractor.
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
    st_insert(lockhash_ptr(self)->tbl, (st_data_t)key, (st_data_t)value);
    RB_OBJ_WRITTEN(self, Qundef, key);
    RB_OBJ_WRITTEN(self, Qundef, value);
    return value;
}

static VALUE
lockhash_delete(VALUE self, VALUE key)
{
    st_data_t k = (st_data_t)key, v;

    lockhash_check_writable(self, "delete");
    return st_delete(lockhash_ptr(self)->tbl, &k, &v) ? (VALUE)v : Qnil;
}

static VALUE
lockhash_clear(VALUE self)
{
    lockhash_check_writable(self, "clear");
    st_clear(lockhash_ptr(self)->tbl);
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
lockhash_inspect_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return rb_sprintf("#<%"PRIsVALUE" %+"PRIsVALUE">",
                      rb_obj_class(arg->self), lockhash_snapshot(arg->self));
}

/* Reading the table needs the lock, so inspect takes it -- unless this thread
 * is inside some other lock, where taking it could deadlock and inspect must
 * not raise either.  Then it just says nothing about the contents. */
static VALUE
lockhash_inspect(VALUE self)
{
    VALUE held = rs_held(rb_thread_current());

    if (!NIL_P(held) && held != self) {
        return rb_sprintf("#<%"PRIsVALUE" ...>", rb_obj_class(self));
    }
    return LOCKHASH_READ(self, lockhash_inspect_body, NULL);
}

void
Init_lockhash_class(void)
{
    rb_cRactorLockHash = rb_define_class_under(rb_cRactor, "LockHash", rb_cObject);
    rb_define_alloc_func(rb_cRactorLockHash, lockhash_alloc);
    rb_define_method(rb_cRactorLockHash, "initialize", lockhash_initialize, -1);

    rb_define_method(rb_cRactorLockHash, "[]", lockhash_aref, 1);
    rb_define_method(rb_cRactorLockHash, "fetch", lockhash_fetch, -1);
    rb_define_method(rb_cRactorLockHash, "key?", lockhash_key_p, 1);
    rb_define_method(rb_cRactorLockHash, "keys", lockhash_keys, 0);
    rb_define_method(rb_cRactorLockHash, "to_h", lockhash_to_h, 0);

    rb_define_method(rb_cRactorLockHash, "[]=", lockhash_aset, 2);
    rb_define_method(rb_cRactorLockHash, "delete", lockhash_delete, 1);
    rb_define_method(rb_cRactorLockHash, "clear", lockhash_clear, 0);
    rb_define_method(rb_cRactorLockHash, "synchronize", lockhash_synchronize, 0);

    rb_define_method(rb_cRactorLockHash, "inspect", lockhash_inspect, 0);

    rb_define_const(rb_cRactorLockHash, "NestedLockError", rb_eRactorNestedLock);
}
