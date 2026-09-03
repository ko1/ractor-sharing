#ifndef RACTOR_SHARING_LOCK_H
#define RACTOR_SHARING_LOCK_H

#include "ruby/ruby.h"
#include "ruby/thread_native.h"
#include "ruby/ractor.h"

/* A lock a Ractor can hold while running Ruby code.
 *
 * The native mutex protects the fields below and nothing else: it is held for a
 * few instructions and never across Ruby code, so a waiter can never keep
 * another Ractor from reaching a GC safepoint.  A thread that has to wait parks
 * on a Ractor::Port of its own, which goes through the VM scheduler, so it
 * rides the M:N scheduler and stays interruptible.
 */

struct rs_waiter {
    VALUE port;                 /* lives on the waiting thread's stack */
    struct rs_waiter *next;
};

struct rs_lock {
    bool locked;
    rb_nativethread_lock_t mutex;
    struct rs_waiter *head, *tail;   /* FIFO; each waiter unlinks itself */
};

void rs_lock_init(struct rs_lock *lk);
void rs_lock_destroy(struct rs_lock *lk);
void rs_lock_acquire(struct rs_lock *lk);
void rs_lock_release(struct rs_lock *lk);

/* a + b when both are Fixnums and the sum still is; Qundef otherwise. */
VALUE rs_fixnum_add(VALUE a, VALUE b);

/* A stored value is deep-frozen in place unless already shareable. */
VALUE rs_shareable_value(VALUE val);

/* A bare String key becomes a frozen copy, the way Hash stores one. */
VALUE rs_hash_key(VALUE key);

/* Which lock object this thread is inside, or Qnil. */
VALUE rs_held(VALUE thread);
void rs_held_set(VALUE thread, VALUE obj);

/* Runs body with +self+ held; a NULL lock marks the thread without locking.  If this thread is already inside +self+, body
 * runs directly when +reentrant+, and raises otherwise; being inside a
 * different lock object always raises. */
VALUE rs_guarded(VALUE self, struct rs_lock *lk, VALUE (*body)(VALUE), void *data,
                 bool reentrant, const char *self_hint);

/* The argument every guarded body receives. */
struct rs_guard_arg {
    VALUE self;
    VALUE thread;
    VALUE prev_held;
    struct rs_lock *lock;
    void *data;
    VALUE (*body)(VALUE);
};

extern VALUE rb_eRactorNestedLock;

void rs_lock_init_class(void);
void Init_oatable(void);
void Init_lockvar_class(void);
void Init_lockhash_class(void);
void Init_keylockhash_class(void);

#endif
