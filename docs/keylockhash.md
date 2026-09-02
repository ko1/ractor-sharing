# Ractor::KeyLockHash

A hash with a lock per key. In database terms, the row lock to
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
req_id = "order-1701".freeze   # keys must be shareable, like everything here
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
m.delete(key)               # returns the old value, or nil
```

Keys and values must be **shareable**; `ArgumentError` otherwise. The map
itself is frozen and shareable, so it can be passed to any Ractor.

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
path, and the API would not change.

A key's own `#hash` or `#eql?` that reaches back into the same map raises
`NestedLockError` rather than deadlocking or being let in: the inner call may
want a shard this thread does not hold.

## When something else fits better

* Two keys that change together, or a consistent snapshot:
  [`Ractor::LockHash`](lockhash.md).
* One key so read-hot that even its own lock is a queue: put that value in a
  [`Ractor::TVar`](tvar.md), whose reads take nothing.
* Values you will not freeze: [`Ractor::ActorHash`](actor_hash.md).

Part of [ractor-sharing](../README.md).
