#ifndef RACTOR_SHARING_OATABLE_H
#define RACTOR_SHARING_OATABLE_H

#include "ruby/ruby.h"
#include "ruby/atomic.h"
#include "ruby/ractor.h"

/* An open-addressed table read without a lock, and reclaimed as one object.
 *
 * Entries live in a flat array of {hash,key,value} slots, so a reader probes
 * the array and reads a value in place: no chain, no per-entry node, nothing
 * allocated on the write path.  A value is one VALUE, so updating one is a
 * single atomic store (or CAS), which is why updates need no lock and leave no
 * shadow copy behind -- the slot is overwritten where it lies.
 *
 * Publication order is what makes a half-built entry unobservable: an inserter
 * writes hash and value first, then publishes the key with a release store, and
 * a reader that loads the key with acquire therefore sees the value that goes
 * with it.
 *
 * Reclamation is the object graph's job.  The table is one T_DATA, so growing
 * means building a new one and dropping the old, which becomes unreachable and
 * is freed by the ordinary GC -- there is no retired list and nothing is freed
 * from inside a mark function.
 */

/* A slot's key is EMPTY until it is published; a deleted entry keeps its key
 * (probe chains must stay intact) and stores TOMBSTONE in its value. */
#define OA_EMPTY     Qundef
#define OA_TOMBSTONE Qundef

struct oa_slot {
    st_index_t hash;
    VALUE key;      /* published with a release store; OA_EMPTY when unused */
    VALUE value;    /* updated in place, atomically; OA_TOMBSTONE when deleted */
    VALUE stash;    /* the committed value while `value` reads oa_locked */
};

struct oa_table {
    long nslots;        /* power of two */
    long live;          /* published keys, tombstones included */
    long entries;       /* live entries, tombstones excluded */
    VALUE next;         /* the table that replaced this one, 0 until it does */
    struct oa_slot slots[1];   /* flexible */
};

/* A slot whose value has been carried to the next table.  A writer that lands
 * on one has arrived too late and must retry there: this is what keeps an
 * update from being lost into a table that is being replaced. */
extern VALUE oa_moved;

/* A slot claimed by a writer whose block must run exactly once.  The committed
 * value moves to `stash` for the duration, so a lock-free reader still sees a
 * real value and never this marker; another writer's compare-and-swap simply
 * fails against it and backs off. */
extern VALUE oa_locked;

/* Claims a slot holding +old+ (writer side).  False if it changed first -- the
 * caller re-reads and claims again, which is why the block need never re-run. */
bool oa_try_claim(struct oa_slot *s, VALUE old);

/* Commits +val+ and releases the claim; oa_unclaim puts +old+ back.  A grow
 * carries a claim into the new table rather than resolving it, so these follow
 * the forwarding chain to wherever the claim ended up. */
void oa_commit(struct oa_table *t, st_index_t hash, VALUE key, struct oa_slot *s, VALUE val);
void oa_unclaim(struct oa_table *t, st_index_t hash, VALUE key, struct oa_slot *s, VALUE old);

/* Builds an empty table object (a T_DATA holding struct oa_table). */
VALUE oa_table_new(long nslots);

/* The table behind a table object. */
struct oa_table *oa_table_ptr(VALUE tbl);

/* Lock-free read for an immediate key (eql is identity).  Qundef if absent. */
VALUE oa_lookup(struct oa_table *t, st_index_t hash, VALUE key);

/* Locked read, may run Ruby via rb_eql, for a non-immediate key. */
VALUE oa_get(struct oa_table *t, st_index_t hash, VALUE key);

/* The atomic shapes this table is built on.  The public RUBY_ATOMIC_* macros
 * are all seq_cst, which is more than this needs: a seq_cst store is a locked
 * xchg on x86, and the read path wants no barrier at all. */
#define OA_LOAD_ACQ(var)     rbimpl_atomic_value_load((volatile VALUE *)&(var), RBIMPL_ATOMIC_ACQUIRE)
#define OA_LOAD_RLX(var)     rbimpl_atomic_value_load((volatile VALUE *)&(var), RBIMPL_ATOMIC_RELAXED)
#define OA_STORE_REL(var, v) rbimpl_atomic_value_store((VALUE *)&(var), (v), RBIMPL_ATOMIC_RELEASE)

/* Identity-only probe: runs no Ruby, so it is safe without the lock.  Only for
 * an immediate key, whose eql? is identity. */
struct oa_slot *oa_find_imm(struct oa_table *t, st_index_t hash, VALUE key);

/* Updates one published slot in place.  A value is one VALUE, so this is a
 * single atomic word: no lock, and no copy left behind. */
bool oa_cas_value(struct oa_slot *s, VALUE old, VALUE val);
void oa_set_value(struct oa_slot *s, VALUE val);
VALUE oa_slot_value(const struct oa_slot *s);

/* Tombstones +key+ (caller holds the writer mutex).  Qundef if absent. */
VALUE oa_delete(struct oa_table *t, st_index_t hash, VALUE key);

/* Finds a published slot for +key+, or NULL.  Callers that intend to CAS a
 * value hold onto the slot; a slot never moves while its table is current. */
struct oa_slot *oa_find(struct oa_table *t, st_index_t hash, VALUE key);

/* Inserts (caller holds the writer mutex, and the key must be absent).
 * Returns false when the table is too full to take another key. */
bool oa_insert(struct oa_table *t, st_index_t hash, VALUE key, VALUE value);

/* True when the table should be rebuilt before the next insert. */
bool oa_needs_grow(const struct oa_table *t);

/* Copies every live entry into a fresh table object and returns it. */
VALUE oa_table_grow(struct oa_table *t, long nslots);

/* A size that fits +entries+ with room to spare. */
long oa_size_for(long entries);

typedef int oa_iter_fn(VALUE key, VALUE value, void *arg);
void oa_foreach(struct oa_table *t, oa_iter_fn *fn, void *arg);

void Init_oatable(void);

#endif
