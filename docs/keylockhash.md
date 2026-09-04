# Ractor::KeyLockHash

A hash whose keys are independent: each key is consistent on its own, and
**reads take no lock at all**, so many Ractors reading a shared hash scale with
the cores. It is optimized for read-mostly and write-once use -- a cache, a memo
table, a registry, a per-client bucket -- where the same keys are read far more
than they are written. Updates and deletes are supported too.

Its reads are like [`Ractor::TVar`](tvar.md)'s: lock-free, and they scale.
`TVar` is the read-mostly cache for a *single* value; `KeyLockHash` is that
cache keyed by many independent keys.

| | atomic unit | reads | two keys together |
|---|---|---|---|
| `LockHash` | the whole hash | take the lock | atomic, its whole point |
| `KeyLockHash` | one key | **lock-free, scale** | **never atomic** here |

```ruby
require "ractor/keylockhash"

buckets = Ractor::KeyLockHash.new
buckets[:quota] = 100
buckets[:quota]                             # read: no lock, scales across Ractors
buckets.update(:quota) { |v| v - 1 }        # read-modify-write, atomic per key
```

## store_if_absent: compute once, read forever

The primitive this class is built around, and where it shines: the value at a
key, or -- only if it is absent -- the block's result, computed once while
owning that entry's claim and stored. A hit never runs the block and **never
takes a lock**, so a memoized value is served at read speed however many Ractors
ask for it.
**nil counts as absent** here, the way `#[]` and `#update` already treat it: a
real cached value is non-nil, so nil (missing, or stored nil) means "compute",
and a nil result is never cached.

```ruby
primes = Ractor::KeyLockHash.new
primes.store_if_absent(97) { |n| (2...n).none? { |d| (n % d).zero? } }   #=> true
```

This is **write-once, read-many** (WORM): each key is computed one time, then
read without bound. Write contention is therefore near zero -- the single write
per key happens once, at the first miss -- and the reads that follow are
lock-free. Simultaneous first-misses on one key still compute once: the losers
wait for the winner and read its result (the cache-stampede, absorbed by the
entry's claim), which is sound because each waiter would have run the identical
computation anyway.

`store_if_absent` is the per-key analogue of `Ractor.store_if_absent`; it is
this class's alone. The single-value members reach the same shape with
`update { |v| v || compute }`, and the multi-key hashes with a `synchronize`
or `call` block, so it is not repeated across the family.

## API

```ruby
m = Ractor::KeyLockHash.new(initial = nil)

m[key]                         # read; lock-free for an immediate key
m.fetch(key, default)          # the usual default / block / KeyError
m.key?(key)
m.keys / m.to_h                # a copy; consistent per key, NOT a whole-map snapshot
m.inspect

m[key] = value                 # atomic write of that key
m.store_if_absent(key) { ... } # the value if non-nil, else compute-and-store once; a hit is lock-free
m.update(key) {|v| new_v }     # read-modify-write under one hold; v is nil if absent
m.increment(key, by = 1)       # update with the block written for you; missing counts as 0
m.delete(key)                  # returns the old value, or nil
```

Values are **made shareable on the way in**, so neither `.freeze` nor
`Ractor.make_shareable` is yours to write (deep-frozen in place; a value that
cannot be raises `Ractor::IsolationError`). Keys must be shareable already,
`ArgumentError` otherwise, with one courtesy borrowed from `Hash` itself: a bare
String key is stored as a frozen copy, and yours stays yours. The map itself is
frozen and shareable, so it can be passed to any Ractor.

## One key at a time

Touching a second lock inside an `update` block raises `Ractor::NestedLockError`,
another key of the same map included: the shape "lock A, then grab B" is where
deadlocks come from, and this class refuses it at the door. Two keys that must
change together are [`Ractor::LockHash`](lockhash.md)'s job; several objects
changing together are [`Ractor::TVar`](tvar.md)'s.

Because reads take no lock, a read *is* allowed to run during another key's
update, and a key's own `#hash` that reads the same map neither deadlocks nor
raises -- the inner read just runs. (A key's `#eql?` reaching for another lock
during a write still raises, since that runs under the lock.)

For the same reason, `keys` and `to_h` are not a snapshot of the whole map at
one moment. A consistent cross-key snapshot is again LockHash territory.

## How it is built

The storage has the same two-level shape as Ruby's `st_table`: an
open-addressed **bins** index points at stable **entries**. Entries are allocated
in append-only C chunks, not as one Ruby object per key.

* A **reader** atomically loads the current bins generation, probes it, then
  atomically loads the stable entry's value. An immediate key compares by
  identity, so this path runs no Ruby and reaches no interrupt checkpoint.
* A **resize** builds a complete, larger bins object in private, pointing it at
  the same entries, then publishes it with one release store. Readers therefore
  see either a complete old index or a complete new one; Ruby's GC reclaims the
  old bins after the no-safepoint readers have left it.
* An **update block** claims its entry, releases the structural lock, and runs in
  the caller. Contenders on that entry park on Ports created in their own
  Ractors. Commit or rollback changes the same stable entry and wakes them, so a
  long computation neither moves during resize nor holds up another key.
* A **new key** alone takes the structural lock: it appends an entry and
  publishes its pointer in the current bins. `store_if_absent` publishes the
  claimed entry first and runs its computation after releasing that lock, so
  misses for different keys compute in parallel.

The C sources divide those jobs deliberately:

* `keylockhash.c` owns the Ruby object and API: key/value validation, the
  structural lock, nested-operation rules, block execution, and the ordering of
  lookup, claim, commit or rollback, and wakeup.
* `oatable.c` supplies the storage/concurrency mechanism: replaceable bins
  generations, append-only stable entries, atomic value/claim transitions, and
  the Port waiter list. It does not call user update blocks or decide API
  semantics.

Entries are deliberately append-only. Deleting a key makes its value logically
absent but retains the entry for reuse by the same key; bins generations are the
part reclaimed by GC. This favours the registry and write-once cache workloads
the class is intended for over a workload that continually invents and deletes
different keys. Compaction is not implemented yet: in the churn benchmark,
eight Ractors inserting and deleting 50,000 distinct keys each leave about
16 MB of entry storage after a full GC. Entries retain their keys as well; the
16 MB is only the C arena reported by the map and excludes those Ruby objects.
See [the churn benchmark](../benchmark/keylockhash_churn.rb) before choosing
this class for an unbounded key-churn workload.

## Performance

Nanoseconds per operation across all Ractors, 16 cores, governor `performance`,
ruby 4.1.0dev, median of three; `benchmark/family.rb` and the trials record
produce these.

**Reads of one shared, hot key scale, where a locked hash collapses** -- the
property that had been `TVar`'s alone:

| Ractors | `KeyLockHash#[]` (ns) | `TVar#value` (ns) | `LockHash#[]` (ns) |
|---:|---:|---:|---:|
| 1 | 65 | 66 | 106 |
| 4 | 20 | 35 | 461 |
| 16 | **12** | 9 | 421 |

`store_if_absent` on one hot key -- the memoize path -- scales the same way,
because a hit is a lock-free read: **7 ns** at sixteen Ractors, against a locked
hash's memoize under one lock at **496**.

Writes do not scale on one key (one key admits one claim: 1202 ns for sixteen
Ractors on the *same* key) and cost more on a bulk build of fresh keys (~12x a
plain hash). Spread over independent keys they scale like the reads -- one
shared map with a key per Ractor updates at **22 ns** for sixteen against
`LockHash`'s **593** -- but the reason to choose this class is the read column.

## Stress testing

The extended suite races shared and independent keys, rollback, deletion,
equivalent and colliding keys, resize while an update block is held, repeated
`store_if_absent` waves, the Fixnum/Bignum boundary, and explicit GC/compaction.
It is opt-in so normal CI stays quick:

```
rake stress:keylockhash

KLH_STRESS_WORKERS=16 KLH_STRESS_ROUNDS=10000 \
  KLH_STRESS_GC_ROUNDS=250 rake stress:keylockhash
```

The parameters are `KLH_STRESS_SEEDS`, `KLH_STRESS_WORKERS`,
`KLH_STRESS_ROUNDS`, `KLH_STRESS_GC_ROUNDS`, `KLH_STRESS_COMPACT` (set to `0`
to skip compaction), and `KLH_STRESS_TIMEOUT`. The strong configuration above
passes on Ruby 4.0.2.

One current-development caveat: Ruby master `69b49ac7ae` can crash in
`Ractor::Port#receive` when explicit concurrent GC hammers a waiting native
lock. The same minimal failure reproduces with `LockVar` and without
`KeyLockHash`, while the Ruby 4.0.2 stress run passes; this is therefore tracked
as a Ruby development-snapshot Port/GC issue rather than a stable-entry failure.

## When something else fits better

* Two keys that change together, or a consistent snapshot:
  [`Ractor::LockHash`](lockhash.md).
* A hash rewritten as often as read, or values you will not freeze:
  [`Ractor::ActorHash`](actor_hash.md).
* A single cached value, not a hash of them: [`Ractor::TVar`](tvar.md), whose
  reads are lock-free and scale the same way.

A worked cache backend, dog-pile protection included, is
[examples/15_cache_backend.rb](../examples/15_cache_backend.rb); a two-shape
memoization (this and an owner-held sieve) is
[examples/19_prime_memo.rb](../examples/19_prime_memo.rb).

Part of [ractor-sharing](../README.md).
