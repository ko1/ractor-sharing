#include "lock.h"

VALUE rb_eRactorNestedLock;
static VALUE rb_eRactorClosed;
static ID id_new, id_receive, id_push, id_held;
static VALUE sym_wakeup;

void
rs_lock_init(struct rs_lock *lk)
{
    lk->locked = false;
    lk->head = lk->tail = NULL;
    rb_native_mutex_initialize(&lk->mutex);
}

void
rs_lock_destroy(struct rs_lock *lk)
{
    rb_native_mutex_destroy(&lk->mutex);
}

/* --- waiter queue: caller holds the native mutex ------------------------- */

static void
rs_enqueue(struct rs_lock *lk, struct rs_waiter *w)
{
    w->next = NULL;
    if (lk->tail) lk->tail->next = w; else lk->head = w;
    lk->tail = w;
}

static void
rs_unlink(struct rs_lock *lk, struct rs_waiter *target)
{
    struct rs_waiter **pp = &lk->head, *prev = NULL;
    while (*pp) {
        if (*pp == target) {
            *pp = target->next;
            if (lk->tail == target) lk->tail = prev;
            return;
        }
        prev = *pp;
        pp = &(*pp)->next;
    }
}

/* Copies the VALUE, not the node: the node lives on a stack frame that may be
 * gone once the mutex is released. */
static VALUE
rs_next_port(struct rs_lock *lk)
{
    return lk->head ? lk->head->port : Qfalse;
}

static VALUE
rs_send_wakeup(VALUE port)
{
    rb_funcall(port, id_push, 1, sym_wakeup);
    return Qtrue;
}

/* The waiter's Ractor is gone, which closed its port: that wakeup is moot. */
static VALUE
rs_wakeup_lost(VALUE unused, VALUE err)
{
    return Qfalse;
}

/* Wakes the first waiter, if the lock is free and anybody is queued.  Runs Ruby
 * code, so the native mutex must be released.  Waking just one is enough: only
 * one thread can take the lock, and a waiter that leaves without taking it
 * wakes the next.  A waiter whose port has been closed is skipped. */
static void
rs_wake_next(struct rs_lock *lk)
{
    VALUE failed = Qfalse;
    int i;

    for (i = 0; i < 8; i++) {
        VALUE port;

        rb_native_mutex_lock(&lk->mutex);
        port = lk->locked ? Qfalse : rs_next_port(lk);
        rb_native_mutex_unlock(&lk->mutex);

        if (!port || port == failed) return;
        if (RTEST(rb_rescue2(rs_send_wakeup, port, rs_wakeup_lost, Qnil,
                             rb_eRactorClosed, (VALUE)0))) {
            return;
        }
        failed = port;
    }
}

/* --- acquire / release --------------------------------------------------- */

struct rs_wait_arg {
    struct rs_lock *lk;
    struct rs_waiter waiter;
};

static VALUE
rs_wait_body(VALUE ptr)
{
    struct rs_wait_arg *arg = (struct rs_wait_arg *)ptr;
    return rb_funcall(arg->waiter.port, id_receive, 0);
}

/* Leaving the queue, woken or interrupted.  If the lock is free and somebody is
 * still queued, pass the wakeup on: the signal that reached us may have been
 * meant for the queue, and nobody else is going to send another one. */
static VALUE
rs_wait_ensure(VALUE ptr)
{
    struct rs_wait_arg *arg = (struct rs_wait_arg *)ptr;

    rb_native_mutex_lock(&arg->lk->mutex);
    rs_unlink(arg->lk, &arg->waiter);
    rb_native_mutex_unlock(&arg->lk->mutex);

    rs_wake_next(arg->lk);
    return Qnil;
}

void
rs_lock_acquire(struct rs_lock *lk)
{
    struct rs_wait_arg arg;
    bool have_port = false;

    for (;;) {
        rb_native_mutex_lock(&lk->mutex);
        if (!lk->locked) {
            lk->locked = true;
            rb_native_mutex_unlock(&lk->mutex);
            return;
        }
        rb_native_mutex_unlock(&lk->mutex);

        if (!have_port) {
            /* Allocating can trigger a GC, so never under the mutex. */
            arg.lk = lk;
            arg.waiter.next = NULL;
            arg.waiter.port = rb_funcall(rb_const_get(rb_cRactor, rb_intern("Port")), id_new, 0);
            have_port = true;
        }

        rb_native_mutex_lock(&lk->mutex);
        if (!lk->locked) {
            lk->locked = true;
            rb_native_mutex_unlock(&lk->mutex);
            return;
        }
        rs_enqueue(lk, &arg.waiter);
        rb_native_mutex_unlock(&lk->mutex);

        /* Parks through the VM scheduler: interruptible and M:N friendly.
         * A spurious wakeup only costs another turn around this loop. */
        rb_ensure(rs_wait_body, (VALUE)&arg, rs_wait_ensure, (VALUE)&arg);
    }
}

void
rs_lock_release(struct rs_lock *lk)
{
    bool waiting;

    rb_native_mutex_lock(&lk->mutex);
    lk->locked = false;
    waiting = lk->head != NULL;
    rb_native_mutex_unlock(&lk->mutex);

    /* Nobody queued is the common case, and it is already answered above: taking
     * the mutex a second time to find that out would double the cost of an
     * uncontended release. */
    if (!waiting) return;

    /* Waiters stay queued until they wake by themselves, so a wakeup lost to an
     * interrupt here is retried by the next release. */
    rs_wake_next(lk);
}

/* --- held marker / guarded ------------------------------------------------ */

/* The "which lock am I inside" marker is per Ruby thread, kept in fiber-local
 * storage rather than an ivar on the Thread object: a Thread stores ivars in a
 * generic table (a hash lookup each time), and this is read once and written
 * twice on every guarded call.  It must not be native-thread-local -- the M:N
 * scheduler moves fibers across native threads, and a block that blocks would
 * then read another fiber's marker. */
VALUE
rs_held(VALUE thread)
{
    return rb_thread_local_aref(thread, id_held);
}

void
rs_held_set(VALUE thread, VALUE obj)
{
    rb_thread_local_aset(thread, id_held, obj);
}

static VALUE
rs_restore_held(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    rs_held_set(arg->thread, arg->prev_held);
    return Qnil;
}

/* Restoring the marker runs Ruby-visible code that can raise -- a frozen Thread
 * makes even the fiber-local store raise FrozenError -- so it is protected, and
 * the release runs whether or not it did.  Skipping the release once stranded
 * the lock for the life of the process. */
static VALUE
rs_guard_ensure(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;
    int state = 0;

    rb_protect(rs_restore_held, (VALUE)arg, &state);
    if (arg->lock) rs_lock_release(arg->lock);
    if (state) rb_jump_tag(state);
    return Qnil;
}

/* Marks the lock held for the whole body, reads included.  A read runs Ruby it
 * does not control -- a key's #hash, a value's #inspect -- and that code reaching
 * back into this object used to wait for a lock its own frame was holding.  With
 * the marker set it is reentrant instead, and reaching for a different lock
 * raises rather than inverting the order. */
static VALUE
rs_guard_body(VALUE ptr)
{
    struct rs_guard_arg *arg = (struct rs_guard_arg *)ptr;

    rs_held_set(arg->thread, arg->self);
    return arg->body(ptr);
}

VALUE
rs_guarded(VALUE self, struct rs_lock *lk, VALUE (*body)(VALUE), void *data,
           bool reentrant, const char *self_hint)
{
    struct rs_guard_arg arg;

    arg.self = self;
    arg.thread = rb_thread_current();
    arg.prev_held = rs_held(arg.thread);
    arg.lock = lk;
    arg.data = data;

    if (arg.prev_held == self) {
        if (reentrant) return body((VALUE)&arg);   /* already marked, already held */
        rb_raise(rb_eRactorNestedLock, "already inside this %"PRIsVALUE"; %s",
                 rb_obj_class(self), self_hint);
    }
    if (!NIL_P(arg.prev_held)) {
        rb_raise(rb_eRactorNestedLock,
                 "already inside another %"PRIsVALUE"; "
                 "use Ractor::TVar to change several of them together",
                 rb_obj_class(arg.prev_held));
    }

    arg.body = body;
    /* A NULL lock marks the thread without taking anything: for a body that is
     * lock-free but still must refuse a second key, the refusal being the
     * design and not a deadlock cure. */
    if (lk) rs_lock_acquire(lk);
    /* No interrupt can land between the line above and the ensure below, so
     * nothing here may run Ruby: marking the lock held is the body's first act,
     * inside the ensure, not a step before it. */
    return rb_ensure(rs_guard_body, (VALUE)&arg, rs_guard_ensure, (VALUE)&arg);
}

/* Hash dups and freezes a bare String key rather than rejecting it, and so do
 * we: the copy is shareable, and the caller's string stays their own. */
VALUE
rs_hash_key(VALUE key)
{
    if (RB_TYPE_P(key, T_STRING) && !RB_OBJ_FROZEN(key)) {
        return rb_str_new_frozen(key);
    }
    return key;
}

VALUE
rs_fixnum_add(VALUE a, VALUE b)
{
    long x, y;

    if (!FIXNUM_P(a) || !FIXNUM_P(b)) return Qundef;
    x = FIX2LONG(a); y = FIX2LONG(b);
    if (y > 0 ? x > FIXNUM_MAX - y : x < FIXNUM_MIN - y) return Qundef;
    return LONG2FIX(x + y);
}

/* Values are made shareable on the way in: a frozen literal passes through
 * untouched, anything else is deep-frozen IN PLACE.  Storing a value here
 * means sharing it. */
VALUE
rs_shareable_value(VALUE val)
{
    if (RB_UNLIKELY(!rb_ractor_shareable_p(val))) {
        return rb_ractor_make_shareable(val);
    }
    return val;
}

void
rs_lock_init_class(void)
{
    id_new = rb_intern("new");
    id_receive = rb_intern("receive");
    id_push = rb_intern("<<");
    id_held = rb_intern("__ractor_sharing_held__");
    sym_wakeup = ID2SYM(rb_intern("wakeup"));
    rb_gc_register_mark_object(sym_wakeup);
    rb_eRactorClosed = rb_const_get(rb_cRactor, rb_intern("ClosedError"));
    rb_gc_register_mark_object(rb_eRactorClosed);
    rb_eRactorNestedLock = rb_define_class_under(rb_cRactor, "NestedLockError", rb_eThreadError);
    rb_gc_register_mark_object(rb_eRactorNestedLock);
}

void
Init_lock(void)
{
    rb_ext_ractor_safe(true); /* these methods are safe to call from any Ractor */
    rs_lock_init_class();
    Init_oatable();
    Init_lockvar_class();
    Init_lockhash_class();
    Init_keylockhash_class();
}
