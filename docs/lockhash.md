# Ractor::LockHash

A Hash that Ractors can share. Reads are allowed anywhere; every write goes
through `synchronize`, and whatever one `synchronize` changes, other Ractors see
all of it or none of it.

```ruby
require "ractor/lockhash"

board = Ractor::LockHash.new

4.times.map do |i|
  Ractor.new(board, i) do |b, id|
    100.times {|n| b.synchronize {|x| x[id] = n } }
  end
end.each(&:join)

board.to_h #=> {0 => 99, 1 => 99, 2 => 99, 3 => 99}
```

## Why not a LockVar holding a Hash

You can put a frozen Hash in a [`Ractor::LockVar`](lockvar.md), but then changing
one entry copies the whole thing:

```ruby
lv = Ractor::LockVar.new({}.freeze)
lv.update { it.merge(k: 1).freeze }   # O(n) per write
```

`LockHash` keeps a real Hash and writes into it, so one entry costs one entry.

## API

```ruby
h = Ractor::LockHash.new(initial = nil)

h[key]                # read
h.fetch(key, default) # read, with the usual default / block / KeyError
h.key?(key)
h.size / h.empty?
h.keys / h.to_h       # a frozen, shareable snapshot of the whole hash

h.synchronize {|h| ... }   # the only place writes are allowed
h[key] = value             #   inside synchronize
h.delete(key)              #   inside synchronize
h.clear                    #   inside synchronize
```

Keys and values must be **shareable**; `ArgumentError` otherwise. The LockHash
itself is frozen and shareable, so it can be passed to any Ractor.

### Writes only inside `synchronize`

```ruby
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
not: taking a second LockHash, or a LockVar, from inside a `synchronize` raises
`Ractor::NestedLockError`, because that is where lock-order deadlocks come from.
Several objects that must change together are [`Ractor::TVar`](tvar.md)'s job.

There is no rollback either. A block that raises keeps whatever it had already
written; the lock is released, nothing more.

## The cost of that atomicity

One lock covers the whole hash, so **writes to unrelated keys wait for each
other**, and a snapshot is O(n). A hash written to constantly is better modelled
as one [`Ractor::LockVar`](lockvar.md) per key, which scales with the cores.
That is open to you whenever you never need two keys to change together.

Acquisition is not FIFO: a thread may barge ahead of waiters, so readers hammering
a hash in a tight loop can starve a writer. Keep sections short, and give busy
reader loops something else to do between reads.

## Keep the block short

The block holds the lock while it runs, so every other reader and writer of this
hash waits for it. Change the entries and nothing else: no IO, no waiting on
anything, no calling out to code that might.

Part of [ractor-sharing](../README.md).
