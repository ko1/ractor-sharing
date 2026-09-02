# Ractor::LockHash

A Hash that Ractors can share, for **keys that change together**. Reads are
allowed anywhere; every write goes through `synchronize`, and whatever one
`synchronize` changes, other Ractors see all of it or none of it.

```ruby
require "ractor/lockhash"

ledger = Ractor::LockHash.new(total: 0)

4.times.map do |i|
  Ractor.new(ledger, i) do |b, id|
    100.times do
      b.synchronize {|x| x["worker_#{id}"] = (x["worker_#{id}"] || 0) + 1; x[:total] += 1 }
    end
  end
end.each(&:join)

ledger.to_h[:total] #=> 400
```

Every section moves a row **and** the total, so no reader and no `to_h`
snapshot ever catches them apart. Keys that never change together do not need
this lock, or its queue: they belong in
[`Ractor::KeyLockHash`](keylockhash.md).

## Why not a LockVar holding a Hash

You can put a frozen Hash in a [`Ractor::LockVar`](lockvar.md), but then changing
one entry copies the whole thing:

```ruby
lv = Ractor::LockVar.new({})
lv.update { it.merge(k: 1) }   # O(n) per write
```

`LockHash` keeps a real Hash and writes into it, so one entry costs one entry.

## API

```ruby
h = Ractor::LockHash.new(initial = nil)

h[key]                # read
h.fetch(key, default) # read, with the usual default / block / KeyError
h.key?(key)
h.keys / h.to_h       # a copy of the whole hash as it was at one moment
h.inspect

h.synchronize {|h| ... }   # the only place writes are allowed; yields the LockHash
h[key] = value             #   inside synchronize
h.delete(key)              #   inside synchronize
h.clear                    #   inside synchronize
```

There is no `size` and no `empty?`. A count handed back after the lock is
released is already stale, and inside a section `keys` says the same thing.

`fetch` prefers its block to an explicit default, as `Hash#fetch` does, and runs
that block **after** the lookup has released the lock, so a default that reads
this hash again is fine.

Values are **made shareable on the way in** (deep-frozen in place; a value
that cannot be raises `Ractor::IsolationError`). Keys must be shareable
already, `ArgumentError` otherwise, with one courtesy borrowed from `Hash`
itself: a bare String key is stored as a frozen copy, and yours stays yours.
The LockHash
itself is frozen and shareable, so it can be passed to any Ractor. `keys` and
`to_h` return plain mutable copies, yours to reshape; everything inside them is
shareable already, so `Ractor.make_shareable(h.to_h)` is all it takes to hand
one to another Ractor.

### Writes only inside `synchronize`

```ruby
h = Ractor::LockHash.new
h[:a] = 1
# => NoMethodError: '[]=' is only allowed inside Ractor::LockHash#synchronize
```

It is a `NoMethodError` for the same reason calling a private method is: the
method is there, but not callable from where you are.

Every write being inside a block is what makes reading an entry and writing it
back one step rather than two:

```ruby
# WRONG: refused, and it was a lost update anyway
h[:hits] = h[:hits] + 1
```

```ruby
h = Ractor::LockHash.new(hits: 0)
h.synchronize {|h| h[:hits] = h[:hits] + 1 }   # right
```

The block is handed the LockHash, **never the Hash inside it**, so no reference
to the state can escape and be written to later, or from another Ractor.

### The two idioms

Almost everything a shared hash gets used for is one of these, and both are one
`synchronize`:

```ruby
h = Ractor::LockHash.new
k = :key

h.synchronize {|h| h[k] ||= 42 }                 # memoize: computed once, by one caller
h.synchronize {|h| h[:n] = (h[:n] || 0) + 1 }    # count: read and write in one step
```

There is no `compute` or `fetch_or_store` here. One lock covers the whole hash,
so a dedicated method for one key would run at exactly the same speed as the
block above, and only spend a name. Such methods start to mean something when a
lock can be taken per key, and this one is not. See below.

### What one `synchronize` gives you

Everything it changes becomes visible together. A reader calling `[]` or `to_h`
waits for a section in flight rather than looking inside one:

```ruby
board = Ractor::LockHash.new
i = 1
board.synchronize {|b| b[:x] = i; b[:y] = i }   # a reader never sees x != y
```

That is atomicity **across the keys of this hash**. Across separate objects it is
not: taking a *different* LockHash, or a LockVar, from inside a `synchronize`
raises `Ractor::NestedLockError`, because that is where lock-order deadlocks come
from. Several objects that must change together are [`Ractor::TVar`](tvar.md)'s
job. Nesting `synchronize` on the *same* hash is allowed, so a section may call a
method that takes one again.

There is no rollback either. A block that raises keeps whatever it had already
written; the lock is released, nothing more.

## The cost of that atomicity

One lock covers the whole hash, so **writes to unrelated keys wait for each
other**, and a snapshot is O(n). A hash written to constantly is better modelled
as one lock per key -- [`Ractor::KeyLockHash`](keylockhash.md), the row lock to
this class's table lock -- which scales with the cores. That is open to you
whenever you never need two keys to change together.

**Reads take the lock too, so they do not scale either.** Sixteen Ractors reading
one shared LockHash cost 489 ns per read, against 23 ns when each has a hash of
its own; a [`Ractor::TVar`](tvar.md) read costs 9 ns whether it is shared or not,
because it takes no lock. One exclusive lock covers the whole hash, so a reader cannot be let in beside a
writer the way a TVar's single slot can. If your load is read heavy
and the hash is shared, that is the number that will decide it.

Acquisition is not FIFO: a thread may barge ahead of waiters, so readers hammering
a hash in a tight loop can starve a writer. Keep sections short, and give busy
reader loops something else to do between reads.

## Keep the block short

The block holds the lock while it runs, so every other reader and writer of this
hash waits for it. Change the entries and nothing else: no IO, no waiting on
anything, no calling out to code that might.

A worked example is a session store with "log out everywhere":
[examples/16_session_store.rb](../examples/16_session_store.rb). The token and
the per-user index live in one hash, and revoking them one by one would leave
a gap where a logged-out token still authenticates.

Part of [ractor-sharing](../README.md).
