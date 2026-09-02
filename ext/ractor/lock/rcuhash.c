#include "rcuhash.h"

#define RCU_MIN_BUCKETS 8
#define RCU_LOAD_NUM 3          /* grow when size > buckets * 3/4 */
#define RCU_LOAD_DEN 4

static inline struct rcu_node *
head_load(struct rcu_node **slot)
{
    return (struct rcu_node *)RUBY_ATOMIC_PTR_LOAD(*slot);
}

static inline void
head_store(struct rcu_node **slot, struct rcu_node *head)
{
    RUBY_ATOMIC_PTR_SET(*slot, head);
}

static struct rcu_table *
table_new(long nbuckets)
{
    struct rcu_table *t = ruby_xcalloc(1, sizeof(struct rcu_table) +
                                       (nbuckets - 1) * sizeof(struct rcu_node *));
    t->nbuckets = nbuckets;
    t->retired = NULL;
    return t;
}

void
rcu_shard_init(struct rcu_shard *s)
{
    s->table = table_new(RCU_MIN_BUCKETS);
    s->size = 0;
    s->retired_nodes = NULL;
    s->retired_tables = NULL;
}

static void
free_nodes(struct rcu_node *n)
{
    while (n) { struct rcu_node *next = n->retired; ruby_xfree(n); n = next; }
}

static void
free_tables(struct rcu_table *t)
{
    while (t) { struct rcu_table *next = t->retired; ruby_xfree(t); t = next; }
}

void
rcu_shard_destroy(struct rcu_shard *s)
{
    for (long i = 0; i < s->table->nbuckets; i++) {
        struct rcu_node *n = s->table->buckets[i];
        while (n) { struct rcu_node *next = n->next; ruby_xfree(n); n = next; }
    }
    ruby_xfree(s->table);
    free_nodes(s->retired_nodes);
    free_tables(s->retired_tables);
}

/* --- read: immediate keys only, eql is identity (no Ruby, no safepoint) --- */

VALUE
rcu_lookup(struct rcu_shard *s, st_index_t hash, VALUE key)
{
    struct rcu_table *t = (struct rcu_table *)RUBY_ATOMIC_PTR_LOAD(s->table);
    struct rcu_node *n = head_load(&t->buckets[hash & (t->nbuckets - 1)]);

    for (; n; n = n->next)
        if (n->hash == hash && n->key == key) return n->value;
    return Qundef;
}

/* A lookup that may run Ruby (rb_eql), for a non-immediate key -- the caller
 * holds the shard lock, so it is safe. */
VALUE
rcu_get(struct rcu_shard *s, st_index_t hash, VALUE key)
{
    for (struct rcu_node *n = s->table->buckets[hash & (s->table->nbuckets - 1)]; n; n = n->next)
        if (n->hash == hash && (n->key == key || rb_eql(n->key, key))) return n->value;
    return Qundef;
}

/* --- writer side (caller holds the shard's writer mutex) ------------------ */

static struct rcu_node *
node_new(st_index_t hash, VALUE key, VALUE value, struct rcu_node *next)
{
    struct rcu_node *n = ruby_xmalloc(sizeof(struct rcu_node));
    n->hash = hash; n->key = key; n->value = value; n->next = next; n->retired = NULL;
    return n;
}

static void
retire_node(struct rcu_shard *s, struct rcu_node *n)
{
    n->retired = s->retired_nodes;
    s->retired_nodes = n;
}

static struct rcu_node *
chain_find(struct rcu_node *head, st_index_t hash, VALUE key)
{
    for (struct rcu_node *n = head; n; n = n->next)
        if (n->hash == hash && (n->key == key || rb_eql(n->key, key))) return n;
    return NULL;
}

static void
resize_if_needed(struct rcu_shard *s)
{
    struct rcu_table *old = s->table;
    long new_nb = old->nbuckets * 2;

    if (s->size * RCU_LOAD_DEN <= old->nbuckets * RCU_LOAD_NUM) return;
    struct rcu_table *nt = table_new(new_nb);

    for (long i = 0; i < old->nbuckets; i++)
        for (struct rcu_node *n = old->buckets[i]; n; n = n->next) {
            long j = n->hash & (new_nb - 1);
            nt->buckets[j] = node_new(n->hash, n->key, n->value, nt->buckets[j]);
        }

    RUBY_ATOMIC_PTR_SET(s->table, nt);          /* publish new table (no alloc past here) */

    for (long i = 0; i < old->nbuckets; i++) {
        struct rcu_node *n = old->buckets[i];
        while (n) { struct rcu_node *next = n->next; retire_node(s, n); n = next; }
    }
    old->retired = s->retired_tables;
    s->retired_tables = old;
}

static VALUE
rcu_put(struct rcu_shard *s, st_index_t hash, VALUE key, VALUE value)
{
    struct rcu_table *t = s->table;
    long i = hash & (t->nbuckets - 1);
    struct rcu_node *head = t->buckets[i];
    struct rcu_node *found = chain_find(head, hash, key);   /* may run Ruby, may GC */

    if (found && value != Qundef && found->value == value) return found->value;

    VALUE prev = found ? found->value : Qundef;
    int delta = found ? (value == Qundef ? -1 : 0) : (value == Qundef ? 0 : 1);
    struct rcu_node *tail = found ? found->next : NULL;
    struct rcu_node *new_head = (value == Qundef) ? tail : node_new(hash, key, value, tail);

    for (struct rcu_node *n = head; n && n != found; n = n->next)   /* all alloc here */
        new_head = node_new(n->hash, n->key, n->value, new_head);

    head_store(&t->buckets[i], new_head);        /* publish (no alloc past here) */

    for (struct rcu_node *n = head; n && n != found; n = n->next) retire_node(s, n);
    if (found) retire_node(s, found);

    s->size += delta;
    if (delta > 0) resize_if_needed(s);
    return prev;
}

VALUE
rcu_insert(struct rcu_shard *s, st_index_t hash, VALUE key, VALUE value)
{
    return rcu_put(s, hash, key, value);
}

VALUE
rcu_delete(struct rcu_shard *s, st_index_t hash, VALUE key)
{
    if (!chain_find(s->table->buckets[hash & (s->table->nbuckets - 1)], hash, key))
        return Qundef;
    return rcu_put(s, hash, key, Qundef);
}

/* --- GC ------------------------------------------------------------------- */

void
rcu_shard_mark(struct rcu_shard *s)
{
    free_nodes(s->retired_nodes);   s->retired_nodes = NULL;
    free_tables(s->retired_tables); s->retired_tables = NULL;

    for (long i = 0; i < s->table->nbuckets; i++)
        for (struct rcu_node *n = s->table->buckets[i]; n; n = n->next) {
            rb_gc_mark(n->key);
            rb_gc_mark(n->value);
        }
}

size_t
rcu_shard_memsize(const struct rcu_shard *s)
{
    size_t n = sizeof(struct rcu_table) + (s->table->nbuckets - 1) * sizeof(struct rcu_node *);
    for (long i = 0; i < s->table->nbuckets; i++)
        for (struct rcu_node *p = s->table->buckets[i]; p; p = p->next) n += sizeof(struct rcu_node);
    return n;
}

void
rcu_shard_foreach(struct rcu_shard *s, rcu_iter_fn *fn, void *arg)
{
    for (long i = 0; i < s->table->nbuckets; i++)
        for (struct rcu_node *n = s->table->buckets[i]; n; n = n->next)
            if (fn(n->key, n->value, arg) != ST_CONTINUE) return;
}
