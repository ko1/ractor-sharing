# Ractor::ActorHash

A Hash kept by a Ractor of its own. Any Ractor can read and write it, and can
send it work to run where the Hash lives.

```ruby
require "ractor/actor_hash"

h = Ractor::ActorHash.new
h[:hits] = 0
h.call {|db| db[:hits] += 1 }
h.call {|db| db[:log] ||= []; db[:log] << Time.now }   # a value it keeps mutating
```

## Why not LockHash

[`Ractor::LockHash`](lockhash.md) can only hold **shareable** values, so every
change replaces a value with a frozen new one. Here the values never leave the
owner except as copies, so they can be anything, and `call` mutates them in
place on the far side.

The price is the owner: one Ractor per ActorHash, running until the process
ends, and about **9 µs** for a call — where a LockHash operation is a few
hundred **ns**. Reach for this one when the state genuinely will not be frozen;
otherwise LockHash is thirty times cheaper.

## API

```ruby
h = Ractor::ActorHash.new(initial = nil)

h[key]                 # read; the value comes back as a copy
h.fetch(key)           # KeyError when missing; also fetch(key, default) and fetch(key) { ... }
h.key?(key)
h.size / h.empty?
h.keys / h.to_h        # a copy of the whole thing

h[key] = value         # write; the value is copied over
h.delete(key)          # returns what was there
h.clear

h.call        {|db, *args| ... }   # run it on the owner, wait, return its value
h.async_call  {|db, *args| ... }   # do not wait; returns nil
h.future_call {|db, *args| ... }   # returns a Future straight away

h.owner                # the Ractor that keeps the Hash
```

`async` and `future` mean what they mean for
[`Ractor::ActiveObject`](active_object.md), which this is built on: an exception
in an `async_call` reaches `#on_async_exception` on the owner, and one in a
`future_call` is raised by `Future#value`.

### Every entry read or written is one message

`h[key]` and `h[key] = value` are each a single message, so each is atomic by
itself — but two of them are two. Anything that reads and then writes belongs
in one `call`:

```ruby
h[:n] = h[:n] + 1                # wrong: another Ractor can land in between
h.call {|db| db[:n] += 1 }       # right
```

### What comes back is a copy

```ruby
h[:list] = [1]
got = h[:list]
got << 2          # changes the copy, not the Hash
h[:list]          #=> [1]
```

That is the same bargain ETS makes, and it is what lets the values be mutable at
all. To change a value, change it where it lives:

```ruby
h.call {|db| db[:list] << 2 }
```

### The block is isolated

It crosses to another Ractor, so `Ractor.shareable_proc` has to accept it: it may
read outer variables that are **never reassigned** anywhere in their scope, and
everything else has to be passed as an argument.

```ruby
n = compute
h.call {|db| db[:total] += n }        # fine: n is never reassigned

h.call(compute) {|db, n| db[:total] += n }   # always fine
```

Note that "never reassigned" is judged from the whole enclosing scope: one later
assignment to `n` makes every block that reads it impossible to isolate.

## Where it sits

| | shareable values, no Ractor | any values, a Ractor of its own |
|---|---|---|
| one value | [`LockVar`](lockvar.md) | — |
| a hash | [`LockHash`](lockhash.md) | **`ActorHash`** |
| your own class | — | [`ActiveObject`](active_object.md) |

`ActorHash` is `ActiveObject` with the interface already chosen. Use
`ActiveObject` when the state deserves methods of its own.

Part of [ractor-sharing](../README.md).
