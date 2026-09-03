#include "oatable.h"

#define OA_MIN_SLOTS  8
#define OA_LOAD_NUM   1         /* grow past half full */
#define OA_LOAD_DEN   2

static VALUE rb_cOATable;       /* internal: never handed to Ruby code */
VALUE oa_moved;                 /* the "carried to the next table" marker */
VALUE oa_locked;                /* the "a block is running for this slot" marker */

/* The value a reader should see: while a slot is claimed the committed value
 * lives in the stash, so nobody outside ever observes the marker. */
static inline VALUE
oa_committed(const struct oa_slot *s, VALUE v)
{
    return v == oa_locked ? OA_LOAD_ACQ(s->stash) : v;
}

/* Follows the forwarding chain to the table that is current for writing. */
static struct oa_table *
oa_forward(struct oa_table *t)
{
    VALUE nxt;
    while ((nxt = OA_LOAD_ACQ(t->next)) != 0) t = oa_table_ptr(nxt);
    return t;
}

/* --- the table object ----------------------------------------------------- */

static void
oa_mark(void *ptr)
{
    struct oa_table *t = ptr;
    if (t->next) rb_gc_mark(t->next);
    for (long i = 0; i < t->nslots; i++) {
        VALUE k = t->slots[i].key, v = t->slots[i].value;
        if (!RB_UNDEF_P(k)) rb_gc_mark(k);
        if (!RB_UNDEF_P(v) && v != oa_moved && v != oa_locked) rb_gc_mark(v);
        if (!RB_UNDEF_P(t->slots[i].stash)) rb_gc_mark(t->slots[i].stash);
    }
}

static size_t
oa_memsize(const void *ptr)
{
    const struct oa_table *t = ptr;
    return sizeof(struct oa_table) + (t->nslots - 1) * sizeof(struct oa_slot);
}

static const rb_data_type_t oa_data_type = {
    "Ractor::KeyLockHash::table",
    {oa_mark, RUBY_TYPED_DEFAULT_FREE, oa_memsize, NULL},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE
};

struct oa_table *
oa_table_ptr(VALUE tbl)
{
    struct oa_table *t;
    TypedData_Get_Struct(tbl, struct oa_table, &oa_data_type, t);
    return t;
}

VALUE
oa_table_new(long nslots)
{
    struct oa_table *t;
    VALUE obj;
    size_t size;

    if (nslots < OA_MIN_SLOTS) nslots = OA_MIN_SLOTS;
    size = sizeof(struct oa_table) + (nslots - 1) * sizeof(struct oa_slot);
    t = ruby_xcalloc(1, size);
    t->nslots = nslots;
    t->live = t->entries = 0;
    t->next = 0;
    for (long i = 0; i < nslots; i++) {
        t->slots[i].key = OA_EMPTY;
        t->slots[i].value = OA_TOMBSTONE;
        t->slots[i].stash = OA_TOMBSTONE;
    }
    obj = TypedData_Wrap_Struct(rb_cOATable, &oa_data_type, t);
    /* The map that owns this is shareable and reaches its table only from C,
     * so the table has to be declared shareable itself -- freezing alone sets
     * the frozen flag and tells the collector nothing.  No traversal is wanted
     * here (the slots are written from C afterwards), so this sets the flag
     * directly; the type is FROZEN_SHAREABLE for exactly this. */
    rb_obj_freeze(obj);
#ifdef HAVE_RB_OBJ_SET_SHAREABLE
    RB_OBJ_SET_SHAREABLE(obj);
#else
    rb_ractor_make_shareable(obj);   /* no traversal for a typed data */
#endif
    return obj;
}

long
oa_size_for(long entries)
{
    long n = OA_MIN_SLOTS;
    while (n * OA_LOAD_NUM < (entries + 1) * OA_LOAD_DEN) n *= 2;
    return n;
}

bool
oa_needs_grow(const struct oa_table *t)
{
    /* live counts tombstones: a table churned by delete grows (and so is
     * rebuilt, which drops them) rather than filling up with dead probes. */
    return t->live * OA_LOAD_DEN >= t->nslots * OA_LOAD_NUM;
}

/* --- read ----------------------------------------------------------------- */

/* Immediate keys only: eql is identity, so this runs no Ruby and hits no
 * interrupt checkpoint. */
VALUE
oa_lookup(struct oa_table *t, st_index_t hash, VALUE key)
{
    long mask = t->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_slot *s = &t->slots[i];
        VALUE k = OA_LOAD_ACQ(s->key);   /* pairs with the release publish */

        if (RB_UNDEF_P(k)) return Qundef;              /* empty: key is absent */
        if (s->hash == hash && k == key) {
            VALUE v = OA_LOAD_ACQ(s->value);
            if (v == oa_moved) {                       /* carried: read it there */
                return oa_lookup(oa_forward(t), hash, key);
            }
            v = oa_committed(s, v);
            return RB_UNDEF_P(v) ? Qundef : v;         /* tombstone reads as absent */
        }
        i = (i + 1) & mask;
    }
    return Qundef;
}

/* May run Ruby (rb_eql), so the caller holds the writer mutex. */
VALUE
oa_get(struct oa_table *t, st_index_t hash, VALUE key)
{
    struct oa_slot *s = oa_find(t, hash, key);
    if (!s) return Qundef;
    {
        VALUE v = OA_LOAD_ACQ(s->value);
        if (v == oa_moved) return oa_get(oa_forward(t), hash, key);
        v = oa_committed(s, v);
        return RB_UNDEF_P(v) ? Qundef : v;
    }
}

struct oa_slot *
oa_find(struct oa_table *t, st_index_t hash, VALUE key)
{
    long mask;

    t = oa_forward(t);
    mask = t->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_slot *s = &t->slots[i];
        VALUE k = OA_LOAD_ACQ(s->key);

        if (RB_UNDEF_P(k)) return NULL;
        if (s->hash == hash && (k == key || rb_eql(k, key))) return s;
        i = (i + 1) & mask;
    }
    return NULL;
}

/* --- write (caller holds the writer mutex) -------------------------------- */

bool
oa_insert(struct oa_table *t, st_index_t hash, VALUE key, VALUE value)
{
    long mask;

    t = oa_forward(t);          /* never write into a table being replaced */
    mask = t->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_slot *s = &t->slots[i];

        if (RB_UNDEF_P(s->key)) {
            /* Value and hash first, key last: a reader that sees the key with
             * an acquire load therefore sees the value that belongs to it. */
            s->hash = hash;
            s->value = value;
            OA_STORE_REL(s->key, key);   /* publish */
            t->live++;
            t->entries++;
            return true;
        }
        if (s->hash == hash && (s->key == key || rb_eql(s->key, key))) {
            /* A tombstoned slot is reused in place: the key is already here. */
            if (RB_UNDEF_P(s->value)) t->entries++;
            OA_STORE_REL(s->value, value);
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

struct oa_slot *
oa_find_imm(struct oa_table *t, st_index_t hash, VALUE key)
{
    long mask;

    t = oa_forward(t);
    mask = t->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_slot *s = &t->slots[i];
        VALUE k = OA_LOAD_ACQ(s->key);

        if (RB_UNDEF_P(k)) return NULL;
        if (s->hash == hash && k == key) return s;
        i = (i + 1) & mask;
    }
    return NULL;
}

VALUE
oa_slot_value(const struct oa_slot *s)
{
    return OA_LOAD_ACQ(s->value);
}

/* Claiming publishes the stash first, so a reader that then sees the marker
 * finds the committed value waiting for it. */
bool
oa_try_claim(struct oa_slot *s, VALUE old)
{
    if (old == oa_locked || old == oa_moved) return false;
    OA_STORE_REL(s->stash, old);
    return oa_cas_value(s, old, oa_locked);
}

/* Releasing a claim.  The swap can only fail one way -- a grow took the slot,
 * having carried the claim forward -- so the release follows the chain and
 * lands on the slot that now holds it.  Nobody else can touch a claimed slot,
 * so this needs no other retry. */
static void
oa_release(struct oa_table *t, st_index_t hash, VALUE key, struct oa_slot *s, VALUE val)
{
    for (;;) {
        if (oa_cas_value(s, oa_locked, val)) return;
        /* Only a grow can take a claimed slot, so this follows it.  The general
         * probe, not the identity one: a String key would not find itself, and
         * abandoning the claim would wedge that key forever.  Running #eql? is
         * safe here -- a non-immediate key only ever claims under the lock. */
        t = oa_forward(t);
        s = oa_find(t, hash, key);
        if (!s) return;                     /* cannot happen: a claim is never dropped */
    }
}

void
oa_commit(struct oa_table *t, st_index_t hash, VALUE key, struct oa_slot *s, VALUE val)
{
    oa_release(t, hash, key, s, val);
}

void
oa_unclaim(struct oa_table *t, st_index_t hash, VALUE key, struct oa_slot *s, VALUE old)
{
    oa_release(t, hash, key, s, old);
}

/* Puts an already-claimed entry into a fresh table: a grow moves the claim, it
 * does not resolve it, so the owner still owns it on the other side. */
static void
oa_insert_claimed(struct oa_table *t, st_index_t hash, VALUE key, VALUE stash)
{
    long mask = t->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_slot *s = &t->slots[i];
        if (RB_UNDEF_P(s->key)) {
            s->hash = hash;
            s->stash = stash;
            s->value = oa_locked;
            OA_STORE_REL(s->key, key);
            t->live++;
            t->entries++;
            return;
        }
        i = (i + 1) & mask;
    }
}

bool
oa_cas_value(struct oa_slot *s, VALUE old, VALUE val)
{
    return rbimpl_atomic_value_cas(&s->value, old, val,
                                   RBIMPL_ATOMIC_RELEASE, RBIMPL_ATOMIC_RELAXED) == old;
}

void
oa_set_value(struct oa_slot *s, VALUE val)
{
    OA_STORE_REL(s->value, val);
}

VALUE
oa_delete(struct oa_table *t, st_index_t hash, VALUE key)
{
    for (;;) {
        struct oa_slot *s = oa_find(t, hash, key);
        VALUE old;

        if (!s) return Qundef;
        old = OA_LOAD_ACQ(s->value);
        if (RB_UNDEF_P(old)) return Qundef;
        if (old == oa_moved) { t = oa_forward(t); continue; }
        if (old == oa_locked) {          /* a block is running for this key */
            rb_thread_schedule();        /* its owner alone may release it */
            continue;
        }
        /* Swapping, not storing: a plain store would overwrite a claim, wedging
         * the owner's release forever and handing the marker back to Ruby.  The
         * key stays so a probe chain through it does not break; only the value
         * becomes a tombstone, and the next rebuild drops the pair. */
        if (!oa_cas_value(s, old, Qundef)) continue;
        oa_forward(t)->entries--;
        return old;
    }
}

/* Growing runs under the writer lock, but lock-free updates do not stop for
 * it, so the two have to hand off: the forwarding pointer is published first,
 * then each slot is *claimed* with a CAS.  An update that lands before the
 * claim is carried over by it; one that lands after finds oa_moved and retries
 * in the new table.  Neither is lost. */
VALUE
oa_table_grow(struct oa_table *t, long nslots)
{
    VALUE obj = oa_table_new(nslots);
    struct oa_table *nt = oa_table_ptr(obj);

    OA_STORE_REL(t->next, obj);        /* forwarding, before anything moves */

    for (long i = 0; i < t->nslots; i++) {
        struct oa_slot *s = &t->slots[i];
        VALUE k = OA_LOAD_ACQ(s->key), v;

        if (RB_UNDEF_P(k)) continue;
        for (;;) {                     /* claim the slot's final value */
            v = OA_LOAD_RLX(s->value);
            if (v == oa_moved) break;
            if (oa_cas_value(s, v, oa_moved)) break;
        }
        if (v == oa_moved) continue;                   /* already carried */
        if (v == oa_locked) {                          /* carry the claim, not its value */
            oa_insert_claimed(nt, s->hash, k, OA_LOAD_ACQ(s->stash));
            continue;
        }
        if (RB_UNDEF_P(v)) continue;                   /* a tombstone */
        oa_insert(nt, s->hash, k, v);
    }
    return obj;
}

void
oa_foreach(struct oa_table *t, oa_iter_fn *fn, void *arg)
{
    for (long i = 0; i < t->nslots; i++) {
        struct oa_slot *s = &t->slots[i];
        VALUE k = OA_LOAD_ACQ(s->key);
        VALUE v = oa_committed(s, OA_LOAD_ACQ(s->value));
        if (RB_UNDEF_P(k) || RB_UNDEF_P(v) || v == oa_moved) continue;
        if (fn(k, v, arg) != ST_CONTINUE) return;
    }
}

void
Init_oatable(void)
{
    /* An internal class, never reachable from Ruby: it only gives the table
     * objects a home so the GC can mark and free them. */
    rb_cOATable = rb_define_class_under(rb_cRactor, "KeyLockHashTable", rb_cObject);
    rb_undef_alloc_func(rb_cOATable);
    rb_gc_register_mark_object(rb_cOATable);

    /* Unique and unreachable from Ruby, so it can never collide with a value. */
    oa_moved = rb_obj_freeze(rb_obj_alloc(rb_cObject));
    rb_gc_register_mark_object(oa_moved);
    oa_locked = rb_obj_freeze(rb_obj_alloc(rb_cObject));
    rb_gc_register_mark_object(oa_locked);
}
