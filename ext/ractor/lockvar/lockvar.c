#include "ruby/ruby.h"
#include "ruby/thread_native.h"
#include "ruby/ractor.h"

/* Ractor::LockVar - a shareable variable guarded by a pessimistic lock.
 *
 * It is a variable, not a lock: there is no lock/unlock, no owner query.  The
 * lock is only ever held for the duration of #update, which is written here in
 * C so that no interrupt can be delivered between taking the lock and arming
 * the ensure that releases it.
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
 *
 * The lock state is protected by a native mutex, held for a few instructions
 * and never across Ruby code, so a waiter can never keep another Ractor from
 * reaching a GC safepoint. A thread that has to wait parks on a Ractor::Port
 * of its own: Port#receive goes through the VM scheduler, so it rides the M:N
 * scheduler (on by default for non-main Ractors) and stays interruptible.
 */

static VALUE rb_cRactorLockVar;
static VALUE rb_eLockVarNested;
static VALUE rb_eRactorClosed;
static ID id_new, id_receive, id_push, id_held, id_plus;
static VALUE sym_wakeup;

struct lv_waiter {
    VALUE port;                 /* lives on the waiting thread's stack */
    struct lv_waiter *next;
};

struct lockvar {
    VALUE value;
    bool locked;
    rb_nativethread_lock_t lock;
    struct lv_waiter *head, *tail;   /* FIFO; each waiter unlinks itself */
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
    rb_native_mutex_destroy(&lv->lock);
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
    lv->locked = false;
    lv->head = lv->tail = NULL;
    rb_native_mutex_initialize(&lv->lock);
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

/* --- waiter queue: caller holds the native mutex ------------------------- */

static void
lockvar_enqueue(struct lockvar *lv, struct lv_waiter *w)
{
    w->next = NULL;
    if (lv->tail) lv->tail->next = w; else lv->head = w;
    lv->tail = w;
}

static void
lockvar_unlink(struct lockvar *lv, struct lv_waiter *target)
{
    struct lv_waiter **pp = &lv->head, *prev = NULL;
    while (*pp) {
        if (*pp == target) {
            *pp = target->next;
            if (lv->tail == target) lv->tail = prev;
            return;
        }
        prev = *pp;
        pp = &(*pp)->next;
    }
}

/* Port of the waiter to wake, or Qfalse. Copies the VALUE (not the node): the
 * node lives on a stack frame that may be gone once the mutex is released. */
static VALUE
lockvar_next_port(struct lockvar *lv)
{
    return lv->head ? lv->head->port : Qfalse;
}

static VALUE
lockvar_send_wakeup(VALUE port)
{
    rb_funcall(port, id_push, 1, sym_wakeup);
    return Qtrue;
}

/* The waiter's Ractor is gone, which closed its port: that wakeup is moot. */
static VALUE
lockvar_wakeup_lost(VALUE unused, VALUE err)
{
    return Qfalse;
}

/* Wakes the first waiter, if the lock is free and anybody is queued.  Runs Ruby
 * code, so it must be called with the native mutex released.  Waking just one
 * is enough: only one thread can take the lock, and a waiter that leaves without
 * taking it wakes the next.  A waiter whose port has been closed is skipped. */
static void
lockvar_wake_next(struct lockvar *lv)
{
    VALUE failed = Qfalse;
    int i;

    for (i = 0; i < 8; i++) {
        VALUE port;

        rb_native_mutex_lock(&lv->lock);
        port = lv->locked ? Qfalse : lockvar_next_port(lv);
        rb_native_mutex_unlock(&lv->lock);

        if (!port || port == failed) return;
        if (RTEST(rb_rescue2(lockvar_send_wakeup, port, lockvar_wakeup_lost, Qnil,
                             rb_eRactorClosed, (VALUE)0))) {
            return;
        }
        failed = port;
    }
}

/* --- acquire / release --------------------------------------------------- */

struct lv_wait_arg {
    struct lockvar *lv;
    struct lv_waiter waiter;
};

static VALUE
lockvar_wait_body(VALUE ptr)
{
    struct lv_wait_arg *arg = (struct lv_wait_arg *)ptr;
    return rb_funcall(arg->waiter.port, id_receive, 0);
}

/* Leaving the queue, woken or interrupted. If the lock is free and somebody is
 * still queued, pass the wakeup on: the signal that reached us may have been
 * meant for the queue, and nobody else is going to send another one. */
static VALUE
lockvar_wait_ensure(VALUE ptr)
{
    struct lv_wait_arg *arg = (struct lv_wait_arg *)ptr;
    struct lockvar *lv = arg->lv;

    rb_native_mutex_lock(&lv->lock);
    lockvar_unlink(lv, &arg->waiter);
    rb_native_mutex_unlock(&lv->lock);

    lockvar_wake_next(lv);
    return Qnil;
}

static void
lockvar_acquire(VALUE self)
{
    struct lockvar *lv = lockvar_ptr(self);
    struct lv_wait_arg arg;
    bool have_port = false;

    for (;;) {
        rb_native_mutex_lock(&lv->lock);
        if (!lv->locked) {
            lv->locked = true;
            rb_native_mutex_unlock(&lv->lock);
            return;
        }
        rb_native_mutex_unlock(&lv->lock);

        if (!have_port) {
            /* Allocating can trigger a GC, so never under the mutex. */
            arg.lv = lv;
            arg.waiter.next = NULL;
            arg.waiter.port = rb_funcall(rb_const_get(rb_cRactor, rb_intern("Port")), id_new, 0);
            have_port = true;
        }

        rb_native_mutex_lock(&lv->lock);
        if (!lv->locked) {
            lv->locked = true;
            rb_native_mutex_unlock(&lv->lock);
            return;
        }
        lockvar_enqueue(lv, &arg.waiter);
        rb_native_mutex_unlock(&lv->lock);

        /* Parks through the VM scheduler: interruptible and M:N friendly.
         * A spurious wakeup only costs another turn around this loop. */
        rb_ensure(lockvar_wait_body, (VALUE)&arg, lockvar_wait_ensure, (VALUE)&arg);
    }
}

static void
lockvar_release(struct lockvar *lv)
{
    rb_native_mutex_lock(&lv->lock);
    lv->locked = false;
    rb_native_mutex_unlock(&lv->lock);

    /* Waiters stay queued until they wake by themselves, so a wakeup lost to an
     * interrupt here is retried by the next release. */
    lockvar_wake_next(lv);
}

/* --- guarded operations -------------------------------------------------- */

struct lv_guard_arg {
    VALUE self;
    VALUE thread;
    VALUE prev_held;
    VALUE amount;       /* #increment only */
};

/* yields the value and stores what the block returns */
static VALUE
lockvar_update_body(VALUE ptr)
{
    struct lv_guard_arg *arg = (struct lv_guard_arg *)ptr;
    struct lockvar *lv = lockvar_ptr(arg->self);
    VALUE next;

    rb_ivar_set(arg->thread, id_held, arg->self);
    next = rb_yield(lv->value);
    lockvar_check_shareable(next);
    lv->value = next;
    return next;
}

static VALUE
lockvar_guard_ensure(VALUE ptr)
{
    struct lv_guard_arg *arg = (struct lv_guard_arg *)ptr;
    rb_ivar_set(arg->thread, id_held, arg->prev_held);
    lockvar_release(lockvar_ptr(arg->self));
    return Qnil;
}

/* adds amount to the value; + may be anything, so the held marker is set too */
static VALUE
lockvar_increment_body(VALUE ptr)
{
    struct lv_guard_arg *arg = (struct lv_guard_arg *)ptr;
    struct lockvar *lv = lockvar_ptr(arg->self);
    VALUE next;

    rb_ivar_set(arg->thread, id_held, arg->self);
    next = rb_funcall(lv->value, id_plus, 1, arg->amount);
    lockvar_check_shareable(next);
    lv->value = next;
    return next;
}

/* just reads the value; the caller holds the lock */
static VALUE
lockvar_value_body(VALUE ptr)
{
    struct lv_guard_arg *arg = (struct lv_guard_arg *)ptr;
    return lockvar_ptr(arg->self)->value;
}

/* Runs body with the lock held.  No LockVar may be touched from inside an
 * update: +self_hint+ says why for this one. */
static VALUE
lockvar_guarded(VALUE self, VALUE (*body)(VALUE), const char *self_hint, VALUE amount)
{
    struct lv_guard_arg arg;

    arg.self = self;
    arg.thread = rb_thread_current();
    arg.prev_held = rb_attr_get(arg.thread, id_held);
    arg.amount = amount;

    if (arg.prev_held == self) {
        rb_raise(rb_eLockVarNested, "already updating this %"PRIsVALUE"; %s",
                 rb_obj_class(self), self_hint);
    }
    if (!NIL_P(arg.prev_held)) {
        rb_raise(rb_eLockVarNested,
                 "already updating another %"PRIsVALUE"; "
                 "use Ractor::TVar to update several variables together",
                 rb_obj_class(self));
    }

    lockvar_acquire(self);
    /* No interrupt can land between the line above and the ensure below. */
    return rb_ensure(body, (VALUE)&arg, lockvar_guard_ensure, (VALUE)&arg);
}

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
 *
 *     counter.update {|n| n + 1 }
 */
static VALUE
lockvar_update(VALUE self)
{
    rb_need_block();
    return lockvar_guarded(self, lockvar_update_body,
                           "the inner result would be discarded by the outer block", Qnil);
}

/*
 *  call-seq:
 *     lockvar.increment(amount = 1) -> new value
 *
 *  Adds +amount+ to the value under the lock and returns the result; the same as
 *  <code>update {|v| v + amount }</code>.
 */
static VALUE
lockvar_increment(int argc, VALUE *argv, VALUE self)
{
    VALUE amount;
    rb_scan_args(argc, argv, "01", &amount);
    return lockvar_guarded(self, lockvar_increment_body,
                           "the block was given that value already",
                           NIL_P(amount) ? INT2FIX(1) : amount);
}

/* --- value --------------------------------------------------------------- */

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
    return lockvar_guarded(self, lockvar_value_body,
                           "the block was given that value already", Qnil);
}

/* Raw read, for inspect: must never block and never raise. */
static VALUE
lockvar_inspect(VALUE self)
{
    return rb_sprintf("#<%"PRIsVALUE" %+"PRIsVALUE">",
                      rb_obj_class(self), lockvar_ptr(self)->value);
}

void
Init_lockvar(void)
{
    rb_ext_ractor_safe(true); /* these methods are safe to call from any Ractor */

    id_new = rb_intern("new");
    id_receive = rb_intern("receive");
    id_push = rb_intern("<<");
    id_held = rb_intern("__ractor_lockvar_held__");
    id_plus = rb_intern("+");
    sym_wakeup = ID2SYM(rb_intern("wakeup"));
    rb_eRactorClosed = rb_const_get(rb_cRactor, rb_intern("ClosedError"));
    rb_gc_register_mark_object(rb_eRactorClosed);
    rb_gc_register_mark_object(sym_wakeup);

    rb_cRactorLockVar = rb_define_class_under(rb_cRactor, "LockVar", rb_cObject);
    rb_define_alloc_func(rb_cRactorLockVar, lockvar_alloc);
    rb_define_method(rb_cRactorLockVar, "initialize", lockvar_initialize, -1);
    rb_define_method(rb_cRactorLockVar, "value", lockvar_value, 0);
    rb_define_method(rb_cRactorLockVar, "update", lockvar_update, 0);
    rb_define_method(rb_cRactorLockVar, "increment", lockvar_increment, -1);
    rb_define_method(rb_cRactorLockVar, "inspect", lockvar_inspect, 0);

    rb_eLockVarNested = rb_define_class_under(rb_cRactorLockVar, "NestedLockError", rb_eThreadError);
}
