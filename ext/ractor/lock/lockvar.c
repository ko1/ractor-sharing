#include "lock.h"

/* Ractor::LockVar - one shareable value, replaced under a lock.
 *
 * It is a variable, not a lock: there is no lock/unlock and no owner query.
 * The lock is only ever held for the duration of #value, #update or
 * #increment, all written here in C so that no interrupt can be delivered
 * between taking the lock and arming the ensure that releases it.
 *
 * #value takes the lock too, so an update's block is atomic as far as readers
 * are concerned, not just its final store.  That is what an update block needs
 * if it makes anything else observable:
 *
 *     lv.update {|v| $last = v; v + 1 }   # readers always see lv.value > $last
 *
 * Touching any LockVar from inside an update is refused, its own included: the
 * block is already given the value, and a nested update's write would be
 * discarded by the outer block's result.
 */

static VALUE rb_cRactorLockVar;
static ID id_plus;

struct lockvar {
    VALUE value;
    struct rs_lock lock;
};

static void
lockvar_mark(void *ptr)
{
    rb_gc_mark(((struct lockvar *)ptr)->value);
}

static void
lockvar_free(void *ptr)
{
    struct lockvar *lv = ptr;
    rs_lock_destroy(&lv->lock);
    ruby_xfree(lv);
}

static size_t
lockvar_memsize(const void *ptr)
{
    return sizeof(struct lockvar);
}

static const rb_data_type_t lockvar_data_type = {
    "Ractor::LockVar",
    {lockvar_mark, lockvar_free, lockvar_memsize, NULL},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE
};

static struct lockvar *
lockvar_ptr(VALUE self)
{
    struct lockvar *lv;
    TypedData_Get_Struct(self, struct lockvar, &lockvar_data_type, lv);
    return lv;
}

static void
lockvar_check_shareable(VALUE val)
{
    if (RB_UNLIKELY(!rb_ractor_shareable_p(val))) {
        rb_raise(rb_eArgError, "only shareable object are allowed");
    }
}

static VALUE
lockvar_alloc(VALUE klass)
{
    struct lockvar *lv;
    VALUE obj = TypedData_Make_Struct(klass, struct lockvar, &lockvar_data_type, lv);
    lv->value = Qnil;
    rs_lock_init(&lv->lock);
    return obj;
}

static VALUE
lockvar_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE init = Qnil;
    rb_scan_args(argc, argv, "01", &init);
    lockvar_check_shareable(init);
    lockvar_ptr(self)->value = init;
    /* Only the guarded slot changes, so the LockVar itself can be frozen and
     * shared; RUBY_TYPED_FROZEN_SHAREABLE is what permits it for a T_DATA. */
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
    return self;
}

/* --- guarded bodies ------------------------------------------------------- */

static VALUE
lockvar_value_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    return lockvar_ptr(arg->self)->value;
}

/* yields the value and stores what the block returns */
static VALUE
lockvar_update_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockvar *lv = lockvar_ptr(arg->self);
    VALUE next;

    rs_held_set(arg->thread, arg->self);
    next = rb_yield(lv->value);
    lockvar_check_shareable(next);
    lv->value = next;
    return next;
}

/* adds amount to the value; + may be anything, so the held marker is set too */
static VALUE
lockvar_increment_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    struct lockvar *lv = lockvar_ptr(arg->self);
    VALUE next;

    rs_held_set(arg->thread, arg->self);
    next = rb_funcall(lv->value, id_plus, 1, (VALUE)arg->data);
    lockvar_check_shareable(next);
    lv->value = next;
    return next;
}

/* --- methods -------------------------------------------------------------- */

/*
 *  call-seq:
 *     lockvar.update {|value| new_value } -> new_value
 *
 *  Replaces the value with what the block returns, with nothing else able to
 *  read it in between, and returns the new value.
 *
 *  Compute the new value from the one the block is given.  Reading it outside
 *  and using it inside loses whatever landed in between:
 *
 *     v = lv.value; lv.update { v + 1 }   # wrong: v is stale
 *     lv.update { it + 1 }                # right
 */
static VALUE
lockvar_update(VALUE self)
{
    rb_need_block();
    return rs_guarded(self, &lockvar_ptr(self)->lock, lockvar_update_body, NULL, false,
                      "the inner result would be discarded by the outer block");
}

/*
 *  call-seq:
 *     lockvar.increment(amount = 1) -> new value
 *
 *  Adds +amount+ to the value under the lock and returns the result; the same as
 *  <code>update {|v| v + amount }</code>.
 */
/* Fixnum + Fixnum, when the sum is still a Fixnum: no Ruby runs, so nothing can
 * be interrupted and nothing can re-enter. That lets the whole ceremony go --
 * the held marker, the ensure, the shareable check, the method dispatch -- and
 * leaves the lock and one add. Returns Qundef when it does not apply. */
static VALUE
lockvar_fixnum_add(VALUE a, VALUE b)
{
    long x, y;

    if (!FIXNUM_P(a) || !FIXNUM_P(b)) return Qundef;
    x = FIX2LONG(a);
    y = FIX2LONG(b);
    if (y > 0 ? x > FIXNUM_MAX - y : x < FIXNUM_MIN - y) return Qundef;
    return LONG2FIX(x + y);
}

static VALUE
lockvar_increment(int argc, VALUE *argv, VALUE self)
{
    struct lockvar *lv = lockvar_ptr(self);
    VALUE amount;

    rb_scan_args(argc, argv, "01", &amount);
    if (NIL_P(amount)) amount = INT2FIX(1);

    if (FIXNUM_P(amount) && NIL_P(rs_held(rb_thread_current()))) {
        VALUE next;

        rs_lock_acquire(&lv->lock);
        next = lockvar_fixnum_add(lv->value, amount);
        if (!RB_UNDEF_P(next)) lv->value = next;
        rs_lock_release(&lv->lock);

        if (!RB_UNDEF_P(next)) return next;
    }
    return rs_guarded(self, &lv->lock, lockvar_increment_body,
                      (void *)amount, false, "the block was given that value already");
}

/*
 *  call-seq:
 *     lockvar.value -> object
 *
 *  Reads the value under the lock, so it waits for an update in flight and never
 *  sees that update's block half done.  Raises NestedLockError if this thread is
 *  inside any update.
 *
 *  This is a snapshot: true when taken, possibly stale by the time it is used.
 *  Never feed it back into #update.
 */
static VALUE
lockvar_value(VALUE self)
{
    return rs_guarded(self, &lockvar_ptr(self)->lock, lockvar_value_body, NULL, false,
                      "the block was given that value already");
}

static VALUE
lockvar_inspect(VALUE self)
{
    return rb_sprintf("#<%"PRIsVALUE" %+"PRIsVALUE">",
                      rb_obj_class(self), lockvar_ptr(self)->value);
}

void
Init_lockvar_class(void)
{
    id_plus = rb_intern("+");

    rb_cRactorLockVar = rb_define_class_under(rb_cRactor, "LockVar", rb_cObject);
    rb_define_alloc_func(rb_cRactorLockVar, lockvar_alloc);
    rb_define_method(rb_cRactorLockVar, "initialize", lockvar_initialize, -1);
    rb_define_method(rb_cRactorLockVar, "value", lockvar_value, 0);
    rb_define_method(rb_cRactorLockVar, "update", lockvar_update, 0);
    rb_define_method(rb_cRactorLockVar, "increment", lockvar_increment, -1);
    rb_define_method(rb_cRactorLockVar, "inspect", lockvar_inspect, 0);

    rb_define_const(rb_cRactorLockVar, "NestedLockError", rb_eRactorNestedLock);
}
