# Ractor::KeyLockHash

A hash with one lock per key. In database terms, the row lock to
[`Ractor::LockHash`](lockhash.md)'s table lock:

| | atomic unit | unrelated keys | two keys together |
|---|---|---|---|
| `LockHash` | the whole hash | wait for each other | atomic, its whole point |
| `KeyLockHash` | one key | run in parallel | **never atomic** here |

Reach for it when the keys are independent of one another and appear at
runtime: token buckets per client, a get-or-create cache, idempotency keys,
anything shaped "look up my key, change my key, never two at once".

```ruby
require "ractor/keylockhash"

buckets = Ractor::KeyLockHash.new

buckets[:quota] = 100                       # a plain write: no ceremony needed
buckets.update(:quota) { |v| v - 1 }        # read-modify-write, atomic per key
```

`update` exists for one reason: computing the new value from the old one. It
yields the current value (nil for a missing key) and stores what the block
returns, all under one hold of that key's lock, and the block runs exactly
once. Being told nil is being told you created the key, so put-if-absent needs
nothing more:

```ruby
jobs = Ractor::KeyLockHash.new
req_id = "order-1701"   # a bare String key is dup'd and frozen for you, like Hash's
mine = false
jobs.update(req_id) { |v| v ? v : (mine = true; :claimed) }
mine #=> true
jobs.update(req_id) { |v| v ? v : (mine = :again; :claimed) }
mine #=> true
```

## API

```ruby
m = Ractor::KeyLockHash.new(initial = nil)

m[key]                # read, under that key's lock
m.fetch(key, default) # the usual default / block / KeyError; both run unlocked
m.key?(key)
m.keys / m.to_h       # a copy; consistent per key, NOT a whole-map snapshot
m.inspect

m[key] = value              # write, under that key's lock
m.update(key) {|v| new_v }  # read-modify-write under one hold; v is nil if absent
m.increment(key, by = 1)    # update with the block written for you; missing counts as 0
m.delete(key)               # returns the old value, or nil
```

Values are **made shareable on the way in**, so neither `.freeze` nor
`Ractor.make_shareable` is yours to write (deep-frozen in place; a value
that cannot be raises `Ractor::IsolationError`). Keys must be shareable
already, `ArgumentError` otherwise, with one courtesy borrowed from `Hash`
itself: a bare String key is stored as a frozen copy, and yours stays yours.
The map itself is frozen and shareable, so it can be passed to any Ractor.

## One key at a time

Touching any second lock inside `update` raises `Ractor::NestedLockError`,
another key of the same map included: the shape "lock A, then grab B" is where
deadlocks come from, and this class refuses it at the door. Two keys that must
change together are [`Ractor::LockHash`](lockhash.md)'s job; several objects
changing together are [`Ractor::TVar`](tvar.md)'s.

For the same reason, `keys` and `to_h` are not a snapshot of the whole map at
one moment: they visit the keys' locks one at a time. A consistent cross-key
snapshot is again LockHash territory.

## How it is built

Lock striping: keys hash onto 64 shards, each a table behind a
[lock of its own](lockvar.md#implementation-notes), so two keys occasionally
share one. Databases would call the finer design a bucket **latch** plus a row
**lock**; if shard collisions ever show up in a profile, that is the upgrade
path, and the API would not change. One thing databases bundle with their row
locks stays unbundled here: a transaction manager. They can let one
transaction take many row locks because a deadlock detector cleans up the
cycles; this class refuses the second lock at the door instead.

A key's own `#hash` or `#eql?` that reaches back into the same map raises
`NestedLockError` rather than deadlocking or being let in: the inner call may
want a shard this thread does not hold.

## Performance

The number this class exists for, one **shared** map with a key per Ractor,
updates only (median of three, ns per completed update across all Ractors):

| Ractors | `KeyLockHash#update`, own key (ns) | `LockHash`, own key (ns) |
|---:|---:|---:|
| 1 | 451 | 476 |
| 4 | **123** | 1212 |
| 16 | **248** | 1312 |

The table lock pays for every neighbour; the key lock does not. (Sixteen keys
on 64 shards collide now and then, which is why 16 sits above 4.)

Everywhere else it costs what `LockHash` costs: an uncontended update is
372 ns, a read 137 ns, and sixteen Ractors fighting over one *single* key are
one lock's queue again, 1173 ns per update. Measured on 16 cores, governor
`performance`, ruby 4.1.0dev; `benchmark/family.rb` and its `ownkey`
companion in the trials record produce these.

## Keep the block short

The family rule applies unchanged: the block holds that key's lock, so every
other user of *that key* waits for it. Compute the new value and nothing more.

The one deliberate exception is get-or-create caching, where holding the lock
through the computation is the point -- it is what stops eight simultaneous
misses computing eight times. The arithmetic is what justifies it: everyone
waiting would have run the *identical* computation themselves, so each waits
at most what it would have burned, and the system does the work once instead
of eight times. That argument covers exactly this case and no other -- it is
not licence for unrelated slow work under the lock -- and it assumes the
computation reliably finishes: one render stuck on the network wedges its key,
and, keys being striped over 64 shards, the occasional innocent neighbour.
See [examples/15_cache_backend.rb](../examples/15_cache_backend.rb) for the
trade priced and tested.

## When something else fits better

* Two keys that change together, or a consistent snapshot:
  [`Ractor::LockHash`](lockhash.md).
* One key so read-hot that even its own lock is a queue: put that value in a
  [`Ractor::TVar`](tvar.md), whose reads take nothing.
* Values you will not freeze: [`Ractor::ActorHash`](actor_hash.md).

A worked cache backend, dog-pile protection included, is
[examples/15_cache_backend.rb](../examples/15_cache_backend.rb).

Part of [ractor-sharing](../README.md).
