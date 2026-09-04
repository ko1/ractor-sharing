#ifndef RACTOR_SHARING_OATABLE_H
#define RACTOR_SHARING_OATABLE_H

#include "ruby/ruby.h"
#include "ruby/atomic.h"
#include "ruby/ractor.h"
#include "ruby/st.h"
#include "ruby/thread_native.h"

/* KeyLockHash's storage has the same two-level shape as st_table:
 *
 *   bins[] -> stable entries
 *
 * A bins object is one open-addressed index generation.  A resize builds a
 * complete replacement off to the side and publishes it in one atomic store;
 * old bins are reclaimed by Ruby's GC after lock-free readers have left their
 * no-safepoint lookup window.  Entries live in append-only chunks owned by the
 * KeyLockHash, so a value or a long-running claim never moves during resize. */

#define OA_ENTRY_CHUNK_SIZE 256

struct oa_entry {
    st_index_t hash;
    VALUE key;                  /* immutable after publication */
    VALUE value;                /* atomic; Qundef is logically absent */
    VALUE stash;                /* committed value while value is oa_locked */
    size_t claim_id;            /* distinguishes successive wait generations */
};

struct oa_entry_chunk;
struct oa_waiter;

struct oa_store {
    struct oa_entry_chunk *head, *tail;
    rb_nativethread_lock_t wait_mutex;
    struct oa_waiter *waiters;  /* stack-owned nodes, present only while parked */
};

struct oa_bins;

/* Unique internal states, unreachable from Ruby code. */
extern VALUE oa_claiming;
extern VALUE oa_locked;
extern VALUE oa_locked_waiters;
extern VALUE oa_releasing;

static inline bool
oa_busy_value(VALUE value)
{
    return value == oa_claiming || value == oa_locked ||
           value == oa_locked_waiters || value == oa_releasing;
}

/* VALUE atomics. */
#define OA_LOAD_ACQ(var)     rbimpl_atomic_value_load((volatile VALUE *)&(var), RBIMPL_ATOMIC_ACQUIRE)
#define OA_STORE_REL(var, v) rbimpl_atomic_value_store((volatile VALUE *)&(var), (v), RBIMPL_ATOMIC_RELEASE)

void oa_store_init(struct oa_store *store);
void oa_store_destroy(struct oa_store *store);
void oa_store_mark(struct oa_store *store);
size_t oa_store_memsize(const struct oa_store *store);

VALUE oa_bins_new(long nslots);
struct oa_bins *oa_bins_ptr(VALUE obj);
VALUE oa_bins_grow(struct oa_bins *old, long nslots);
bool oa_bins_needs_grow(const struct oa_bins *bins);

/* Probe operations.  oa_find may invoke #eql?; oa_find_imm never invokes Ruby. */
struct oa_entry *oa_find(struct oa_bins *bins, st_index_t hash, VALUE key);
struct oa_entry *oa_find_imm(struct oa_bins *bins, st_index_t hash, VALUE key);
VALUE oa_lookup(struct oa_bins *bins, st_index_t hash, VALUE key);
VALUE oa_get(struct oa_bins *bins, st_index_t hash, VALUE key);

/* Insert a previously unseen key.  The caller serialises structural changes.
 * The claimed form publishes an already-owned entry for a block that will run
 * after the structural lock has been released. */
struct oa_entry *oa_insert(struct oa_store *store, struct oa_bins *bins,
                           st_index_t hash, VALUE key, VALUE value);
struct oa_entry *oa_insert_claimed(struct oa_store *store, struct oa_bins *bins,
                                   st_index_t hash, VALUE key, VALUE old,
                                   size_t *claim_id);

VALUE oa_entry_raw(const struct oa_entry *entry);
VALUE oa_entry_value(const struct oa_entry *entry);
bool oa_entry_cas(struct oa_entry *entry, VALUE old, VALUE value);

/* A claim makes a Ruby block exactly-once without holding the structural lock.
 * Waiters park on Ports belonging to their own Ractors and are woken at the
 * matching claim generation's commit or rollback. */
bool oa_try_claim(struct oa_entry *entry, VALUE old, size_t *claim_id);
bool oa_finish_claim(struct oa_entry *entry, size_t claim_id, VALUE value);
void oa_wake_claim(struct oa_store *store, struct oa_entry *entry,
                   size_t claim_id);
void oa_wait(struct oa_store *store, struct oa_entry *entry);

typedef int oa_iter_fn(VALUE key, VALUE value, void *arg);
void oa_foreach(struct oa_bins *bins, oa_iter_fn *fn, void *arg);

void Init_oatable(void);

#endif
