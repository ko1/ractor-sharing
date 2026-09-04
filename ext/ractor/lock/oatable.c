#include "oatable.h"

#define OA_MIN_SLOTS 8
#define OA_LOAD_NUM  1
#define OA_LOAD_DEN  2

struct oa_entry_chunk {
    struct oa_entry_chunk *next;
    long used;
    struct oa_entry entries[OA_ENTRY_CHUNK_SIZE];
};

struct oa_bins {
    long nslots;                 /* power of two */
    long used;                   /* published entry pointers */
    struct oa_entry *slots[1];
};

struct oa_waiter {
    struct oa_entry *entry;
    size_t claim_id;
    VALUE port;
    bool queued;
    struct oa_waiter *next;
};

static VALUE rb_cOABins;
static VALUE rb_cRactorPort;
static VALUE rb_eRactorClosed;
static ID id_new, id_receive, id_push;
static VALUE sym_wakeup;

VALUE oa_claiming;
VALUE oa_locked;
VALUE oa_locked_waiters;
VALUE oa_releasing;

#define OA_PTR_LOAD(var) \
    ((struct oa_entry *)rbimpl_atomic_ptr_load((void **)&(var), RBIMPL_ATOMIC_ACQUIRE))
#define OA_PTR_STORE(var, val) \
    rbimpl_atomic_ptr_store((volatile void **)&(var), (void *)(val), RBIMPL_ATOMIC_RELEASE)

/* --- bins generations ---------------------------------------------------- */

static size_t
oa_bins_memsize(const void *ptr)
{
    const struct oa_bins *bins = ptr;
    return sizeof(struct oa_bins) + (bins->nslots - 1) * sizeof(struct oa_entry *);
}

static const rb_data_type_t oa_bins_type = {
    "Ractor::KeyLockHash::bins",
    {NULL, RUBY_TYPED_DEFAULT_FREE, oa_bins_memsize, NULL},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE
};

VALUE
oa_bins_new(long nslots)
{
    struct oa_bins *bins;
    VALUE obj;
    size_t size;

    if (nslots < OA_MIN_SLOTS) nslots = OA_MIN_SLOTS;
    size = sizeof(struct oa_bins) + (nslots - 1) * sizeof(struct oa_entry *);
    bins = ruby_xcalloc(1, size);
    bins->nslots = nslots;
    bins->used = 0;
    obj = TypedData_Wrap_Struct(rb_cOABins, &oa_bins_type, bins);
    rb_obj_freeze(obj);
#ifdef HAVE_RB_OBJ_SET_SHAREABLE
    RB_OBJ_SET_SHAREABLE(obj);
#else
    rb_ractor_make_shareable(obj);
#endif
    return obj;
}

struct oa_bins *
oa_bins_ptr(VALUE obj)
{
    struct oa_bins *bins;
    TypedData_Get_Struct(obj, struct oa_bins, &oa_bins_type, bins);
    return bins;
}

bool
oa_bins_needs_grow(const struct oa_bins *bins)
{
    return bins->used * OA_LOAD_DEN >= bins->nslots * OA_LOAD_NUM;
}

static bool
oa_bins_put(struct oa_bins *bins, struct oa_entry *entry)
{
    long mask = bins->nslots - 1;
    long i = (long)(entry->hash & mask);

    for (long n = 0; n <= mask; n++) {
        if (!OA_PTR_LOAD(bins->slots[i])) {
            OA_PTR_STORE(bins->slots[i], entry);
            bins->used++;
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

VALUE
oa_bins_grow(struct oa_bins *old, long nslots)
{
    if (nslots <= old->nslots) nslots = old->nslots * 2;
    VALUE obj = oa_bins_new(nslots);
    struct oa_bins *bins = oa_bins_ptr(obj);

    for (long i = 0; i < old->nslots; i++) {
        struct oa_entry *entry = OA_PTR_LOAD(old->slots[i]);
        if (entry && !oa_bins_put(bins, entry)) rb_bug("KeyLockHash bins rebuild overflow");
    }
    return obj;
}

/* --- append-only entries ------------------------------------------------- */

void
oa_store_init(struct oa_store *store)
{
    store->head = store->tail = NULL;
    store->waiters = NULL;
    rb_native_mutex_initialize(&store->wait_mutex);
}

void
oa_store_destroy(struct oa_store *store)
{
    struct oa_entry_chunk *chunk = store->head;
    while (chunk) {
        struct oa_entry_chunk *next = chunk->next;
        ruby_xfree(chunk);
        chunk = next;
    }
    rb_native_mutex_destroy(&store->wait_mutex);
}

void
oa_store_mark(struct oa_store *store)
{
    for (struct oa_entry_chunk *chunk = store->head; chunk; chunk = chunk->next) {
        for (long i = 0; i < chunk->used; i++) {
            struct oa_entry *entry = &chunk->entries[i];
            VALUE key = entry->key;
            VALUE value = OA_LOAD_ACQ(entry->value);
            VALUE stash = OA_LOAD_ACQ(entry->stash);

            if (!RB_UNDEF_P(key)) rb_gc_mark(key);
            if (!RB_UNDEF_P(value) && value != oa_claiming &&
                value != oa_locked && value != oa_locked_waiters &&
                value != oa_releasing) rb_gc_mark(value);
            if (!RB_UNDEF_P(stash)) rb_gc_mark(stash);
        }
    }
}

size_t
oa_store_memsize(const struct oa_store *store)
{
    size_t size = 0;
    for (const struct oa_entry_chunk *chunk = store->head; chunk; chunk = chunk->next) {
        size += sizeof(*chunk);
    }
    return size;
}

static struct oa_entry *
oa_entry_alloc(struct oa_store *store, st_index_t hash, VALUE key,
               VALUE value, VALUE stash, size_t claim_id)
{
    struct oa_entry_chunk *chunk = store->tail;
    struct oa_entry *entry;

    if (!chunk || chunk->used == OA_ENTRY_CHUNK_SIZE) {
        chunk = ruby_xcalloc(1, sizeof(*chunk));
        if (store->tail) store->tail->next = chunk; else store->head = chunk;
        store->tail = chunk;
    }
    entry = &chunk->entries[chunk->used++];
    entry->hash = hash;
    entry->key = key;
    entry->stash = stash;
    entry->claim_id = claim_id;
    entry->value = value;
    return entry;
}

struct oa_entry *
oa_insert(struct oa_store *store, struct oa_bins *bins,
          st_index_t hash, VALUE key, VALUE value)
{
    struct oa_entry *entry = oa_entry_alloc(store, hash, key, value, Qundef, 0);
    if (!oa_bins_put(bins, entry)) rb_bug("KeyLockHash bins insert overflow");
    return entry;
}

struct oa_entry *
oa_insert_claimed(struct oa_store *store, struct oa_bins *bins,
                  st_index_t hash, VALUE key, VALUE old, size_t *claim_id)
{
    struct oa_entry *entry = oa_entry_alloc(store, hash, key, oa_locked, old, 1);
    if (!oa_bins_put(bins, entry)) rb_bug("KeyLockHash bins insert overflow");
    *claim_id = 1;
    return entry;
}

/* --- lookup -------------------------------------------------------------- */

struct oa_entry *
oa_find_imm(struct oa_bins *bins, st_index_t hash, VALUE key)
{
    long mask = bins->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_entry *entry = OA_PTR_LOAD(bins->slots[i]);
        if (!entry) return NULL;
        if (entry->hash == hash && entry->key == key) return entry;
        i = (i + 1) & mask;
    }
    return NULL;
}

struct oa_entry *
oa_find(struct oa_bins *bins, st_index_t hash, VALUE key)
{
    long mask = bins->nslots - 1;
    long i = (long)(hash & mask);

    for (long n = 0; n <= mask; n++) {
        struct oa_entry *entry = OA_PTR_LOAD(bins->slots[i]);
        if (!entry) return NULL;
        if (entry->hash == hash && (entry->key == key || rb_eql(entry->key, key))) return entry;
        i = (i + 1) & mask;
    }
    return NULL;
}

VALUE
oa_entry_raw(const struct oa_entry *entry)
{
    return OA_LOAD_ACQ(entry->value);
}

VALUE
oa_entry_value(const struct oa_entry *entry)
{
    for (;;) {
        VALUE value = OA_LOAD_ACQ(entry->value);
        if (value == oa_claiming || value == oa_releasing) continue;
        if (value == oa_locked || value == oa_locked_waiters) {
            VALUE stash = OA_LOAD_ACQ(entry->stash);
            /* A commit publishes the value before clearing stash.  Rechecking
             * prevents a reader delayed across that transition from returning
             * the cleared stash or a value belonging to a later claim. */
            value = OA_LOAD_ACQ(entry->value);
            if (value != oa_locked && value != oa_locked_waiters) continue;
            return stash;
        }
        return value;
    }
}

VALUE
oa_lookup(struct oa_bins *bins, st_index_t hash, VALUE key)
{
    struct oa_entry *entry = oa_find_imm(bins, hash, key);
    return entry ? oa_entry_value(entry) : Qundef;
}

VALUE
oa_get(struct oa_bins *bins, st_index_t hash, VALUE key)
{
    struct oa_entry *entry = oa_find(bins, hash, key);
    return entry ? oa_entry_value(entry) : Qundef;
}

bool
oa_entry_cas(struct oa_entry *entry, VALUE old, VALUE value)
{
    return rbimpl_atomic_value_cas(&entry->value, old, value,
                                   RBIMPL_ATOMIC_ACQ_REL,
                                   RBIMPL_ATOMIC_ACQUIRE) == old;
}

/* --- claims and Port-backed waiting ------------------------------------- */

bool
oa_try_claim(struct oa_entry *entry, VALUE old, size_t *claim_id)
{
    size_t id;

    if (old == oa_claiming || old == oa_locked ||
        old == oa_locked_waiters || old == oa_releasing) return false;
    if (!oa_entry_cas(entry, old, oa_claiming)) return false;
    id = rbimpl_atomic_size_fetch_add(&entry->claim_id, 1, RBIMPL_ATOMIC_ACQ_REL) + 1;
    OA_STORE_REL(entry->stash, old);
    OA_STORE_REL(entry->value, oa_locked);
    *claim_id = id;
    return true;
}

static void
oa_unlink_waiter(struct oa_store *store, struct oa_waiter *target)
{
    struct oa_waiter **link = &store->waiters;
    while (*link) {
        if (*link == target) {
            *link = target->next;
            target->queued = false;
            return;
        }
        link = &(*link)->next;
    }
}

struct oa_wait_arg {
    struct oa_store *store;
    struct oa_entry *entry;
    struct oa_waiter waiter;
};

static VALUE
oa_wait_receive(VALUE ptr)
{
    struct oa_wait_arg *arg = (struct oa_wait_arg *)ptr;
    return rb_funcall(arg->waiter.port, id_receive, 0);
}

static VALUE
oa_wait_ensure(VALUE ptr)
{
    struct oa_wait_arg *arg = (struct oa_wait_arg *)ptr;
    rb_native_mutex_lock(&arg->store->wait_mutex);
    if (arg->waiter.queued) oa_unlink_waiter(arg->store, &arg->waiter);
    rb_native_mutex_unlock(&arg->store->wait_mutex);
    return Qnil;
}

void
oa_wait(struct oa_store *store, struct oa_entry *entry)
{
    struct oa_wait_arg arg;
    bool should_wait = false;
    VALUE state;

    /* CLAIMING contains no Ruby or safepoint and lasts only for the publication
     * of stash.  Do not enqueue against the previous claim generation. */
    while (oa_entry_raw(entry) == oa_claiming ||
           oa_entry_raw(entry) == oa_releasing) rb_thread_schedule();
    state = oa_entry_raw(entry);
    if (state != oa_locked && state != oa_locked_waiters) return;

    arg.store = store;
    arg.entry = entry;
    arg.waiter.entry = entry;
    arg.waiter.port = rb_funcall(rb_cRactorPort, id_new, 0);
    arg.waiter.queued = false;
    arg.waiter.next = NULL;

    for (;;) {
        state = oa_entry_raw(entry);
        if (state == oa_locked_waiters) break;
        if (state != oa_locked) return;
        if (oa_entry_cas(entry, oa_locked, oa_locked_waiters)) break;
    }

    rb_native_mutex_lock(&store->wait_mutex);
    /* Do not pair a previous generation's id with the next one's marker. */
    arg.waiter.claim_id = rbimpl_atomic_size_fetch_add(&entry->claim_id, 0,
                                                        RBIMPL_ATOMIC_ACQUIRE);
    if (oa_entry_raw(entry) == oa_locked_waiters &&
        rbimpl_atomic_size_fetch_add(&entry->claim_id, 0,
                                     RBIMPL_ATOMIC_ACQUIRE) == arg.waiter.claim_id) {
        arg.waiter.next = store->waiters;
        store->waiters = &arg.waiter;
        arg.waiter.queued = true;
        should_wait = true;
    }
    rb_native_mutex_unlock(&store->wait_mutex);

    if (should_wait) {
        rb_ensure(oa_wait_receive, (VALUE)&arg, oa_wait_ensure, (VALUE)&arg);
    }
}

static VALUE
oa_send_wakeup(VALUE port)
{
    rb_funcall(port, id_push, 1, sym_wakeup);
    return Qtrue;
}

static VALUE
oa_take_waiter_port(struct oa_store *store, struct oa_entry *entry, size_t claim_id)
{
    VALUE port = Qfalse;
    struct oa_waiter **link;

    rb_native_mutex_lock(&store->wait_mutex);
    link = &store->waiters;
    while (*link) {
        struct oa_waiter *waiter = *link;
        if (waiter->entry == entry && waiter->claim_id == claim_id) {
            *link = waiter->next;
            waiter->queued = false;
            port = waiter->port;
            break;
        }
        link = &waiter->next;
    }
    rb_native_mutex_unlock(&store->wait_mutex);
    return port;
}

void
oa_wake_claim(struct oa_store *store, struct oa_entry *entry, size_t claim_id)
{
    VALUE port;
    VALUE first_error = Qnil;
    int first_state = 0;

    while (RTEST(port = oa_take_waiter_port(store, entry, claim_id))) {
        int state = 0;
        rb_protect(oa_send_wakeup, port, &state);
        if (state) {
            VALUE error = rb_errinfo();
            if (!rb_obj_is_kind_of(error, rb_eRactorClosed) && !first_state) {
                first_state = state;
                first_error = error;
            }
            rb_set_errinfo(Qnil);
        }
    }
    if (first_state) {
        rb_set_errinfo(first_error);
        rb_jump_tag(first_state);
    }
}

bool
oa_finish_claim(struct oa_entry *entry, size_t claim_id, VALUE value)
{
    size_t current = rbimpl_atomic_size_fetch_add(&entry->claim_id, 0,
                                                  RBIMPL_ATOMIC_ACQUIRE);
    bool had_waiters;

    if (current != claim_id) rb_bug("KeyLockHash claim ownership lost");
    for (;;) {
        VALUE state = oa_entry_raw(entry);
        if (state == oa_locked) had_waiters = false;
        else if (state == oa_locked_waiters) had_waiters = true;
        else rb_bug("KeyLockHash claim ownership lost");
        if (oa_entry_cas(entry, state, oa_releasing)) break;
    }
    OA_STORE_REL(entry->stash, Qundef);
    OA_STORE_REL(entry->value, value);
    return had_waiters;
}

/* --- iteration ----------------------------------------------------------- */

void
oa_foreach(struct oa_bins *bins, oa_iter_fn *fn, void *arg)
{
    for (long i = 0; i < bins->nslots; i++) {
        struct oa_entry *entry = OA_PTR_LOAD(bins->slots[i]);
        VALUE value;
        if (!entry) continue;
        value = oa_entry_value(entry);
        if (RB_UNDEF_P(value)) continue;
        if (fn(entry->key, value, arg) != ST_CONTINUE) return;
    }
}

void
Init_oatable(void)
{
    rb_cOABins = rb_define_class_under(rb_cRactor, "KeyLockHashBins", rb_cObject);
    rb_undef_alloc_func(rb_cOABins);
    rb_gc_register_mark_object(rb_cOABins);

    rb_cRactorPort = rb_const_get(rb_cRactor, rb_intern("Port"));
    rb_eRactorClosed = rb_const_get(rb_cRactor, rb_intern("ClosedError"));
    rb_gc_register_mark_object(rb_cRactorPort);
    rb_gc_register_mark_object(rb_eRactorClosed);
    id_new = rb_intern("new");
    id_receive = rb_intern("receive");
    id_push = rb_intern("<<");
    sym_wakeup = ID2SYM(rb_intern("__keylockhash_wakeup__"));

    oa_claiming = rb_obj_freeze(rb_obj_alloc(rb_cObject));
    oa_locked = rb_obj_freeze(rb_obj_alloc(rb_cObject));
    oa_locked_waiters = rb_obj_freeze(rb_obj_alloc(rb_cObject));
    oa_releasing = rb_obj_freeze(rb_obj_alloc(rb_cObject));
    rb_gc_register_mark_object(oa_claiming);
    rb_gc_register_mark_object(oa_locked);
    rb_gc_register_mark_object(oa_locked_waiters);
    rb_gc_register_mark_object(oa_releasing);
}
