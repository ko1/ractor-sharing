#ifndef RACTOR_SHARING_RCUHASH_H
#define RACTOR_SHARING_RCUHASH_H

#include "ruby/ruby.h"
#include "ruby/atomic.h"

/* A hash shard read without a lock.
 *
 * Buckets hold singly-linked chains of immutable nodes {hash,key,value,next}.
 * A reader loads the table pointer once, then the bucket head, and walks next
 * pointers, writing nothing shared -- so reads scale.  A writer (serialized
 * against other writers by the caller's mutex) builds new nodes, rebuilds only
 * the affected chain, and publishes the new head with an atomic store; nodes it
 * replaced are retired, not freed, because a reader may still be walking them.
 *
 * The bucket array and its size live together in one rcu_table, swapped as a
 * unit, so a reader never sees an old size against a new array.
 *
 * Reclamation is deferred: the read window (load table, load head, walk chain)
 * runs no Ruby and hits no interrupt checkpoint for immediate keys, so the GC
 * can only run when no reader is inside it -- GC is the grace period.  Retired
 * nodes and tables are freed at the next mark.
 */

struct rcu_node {
    st_index_t hash;
    VALUE key;
    VALUE value;
    struct rcu_node *next;      /* immutable once published */
    struct rcu_node *retired;   /* free-list link while awaiting reclamation */
};

struct rcu_table {
    long nbuckets;                 /* power of two */
    struct rcu_table *retired;     /* free-list link */
    struct rcu_node *buckets[1];   /* flexible: nbuckets heads */
};

struct rcu_shard {
    struct rcu_table *table;    /* atomic-published */
    long size;                  /* entries; writer-only */
    struct rcu_node *retired_nodes;
    struct rcu_table *retired_tables;
};

void rcu_shard_init(struct rcu_shard *s);
void rcu_shard_destroy(struct rcu_shard *s);

/* Lock-free read for an immediate key (eql is identity).  Qundef if absent. */
VALUE rcu_lookup(struct rcu_shard *s, st_index_t hash, VALUE key);

/* Locked read (may run Ruby via rb_eql), for a non-immediate key. */
VALUE rcu_get(struct rcu_shard *s, st_index_t hash, VALUE key);

/* Writer side (caller holds the shard's writer mutex). */
VALUE rcu_insert(struct rcu_shard *s, st_index_t hash, VALUE key, VALUE value);
VALUE rcu_delete(struct rcu_shard *s, st_index_t hash, VALUE key);

/* GC mark: frees last epoch's retired garbage, then marks every live entry. */
void rcu_shard_mark(struct rcu_shard *s);
size_t rcu_shard_memsize(const struct rcu_shard *s);

typedef int rcu_iter_fn(VALUE key, VALUE value, void *arg);
void rcu_shard_foreach(struct rcu_shard *s, rcu_iter_fn *fn, void *arg);

#endif
