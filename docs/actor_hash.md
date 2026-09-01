# Ractor::ActorHash

A Hash kept by a Ractor of its own. Reading it is a question you ask; every
change is work you send, and the work runs where the Hash is.

```ruby
require "ractor/actor_hash"

h = Ractor::ActorHash.new
h.async_call {|h| h[:hits] = (h[:hits] || 0) + 1 }   # send it and carry on
h[:hits]                                             # ask
```

## Why not LockHash

[`Ractor::LockHash`](lockhash.md) can only hold **shareable** values, so every
change replaces a value with a frozen new one. Here the entries never leave the
owner except as copies, so they can be anything, and a block changes them in
place over there:

```ruby
h.async_call {|h| (h[:log] ||= []) << "a line" }   # a value it goes on appending to
```

The price is the owner: one Ractor per ActorHash, running until the process
ends, and about **2 µs** for a round trip, where a LockHash operation is a few
hundred **ns**. Reach for this one when the state genuinely will not be frozen;
otherwise LockHash is far cheaper.

A write that does not need an answer should be `async_call` or `set` rather than
`call`: not waiting for the reply is worth 3× on sixteen Ractors with a hash each
(244 ns against 750) and 2× on sixteen sharing one (1001 ns against 2006). Reads
pay the full round trip regardless, since a read is the answer.

## API

```ruby
h = Ractor::ActorHash.new(initial = nil)

h[key]                 # read; the value comes back as a copy
h.fetch(key)           # KeyError when missing; also fetch(key, default) and fetch(key) { }
h.key?(key)
h.keys / h.to_h        # a copy of the whole thing

h.set(key, value)                 # send a write; returns nil
h.increment(key, by = 1)          # send an add; returns nil

h.async_call  {|h, *args| ... }   # send it, do not wait; returns nil
h.call        {|h, *args| ... }   # send it and wait; returns what the block returned
h.future_call {|h, *args| ... }   # send it, get a Future straight away
```

There is no `h[key] = value`. A change is a message you send, and an assignment
does not look like one; more to the point, having it invites the two round trips
with a gap in the middle:

```ruby
h[:n] = h[:n] + 1              # not available, and it was a lost update
h.increment(:n)                # one message, and you do not wait for it
```

`set` and `increment` are not shorthand for the block forms. **Their arguments
travel as arguments**, so they are not held to what an isolated block may capture:

```ruby
key = :a
key = :b                             # a local assigned more than once
h.async_call {|h| h[key] = 1 }       # => Ractor::IsolationError
h.set(key, 1)                        # fine
```

For anything else, such as deleting, clearing, or changing a value in place, send
a block.

`async` and `future` mean what they mean for
[`Ractor::ActiveObject`](active_object.md), which this is built on: an exception
in an `async_call` reaches `#on_async_exception` on the owner, and one in a
`future_call` is raised by `Future#value`. Calls from one Ractor arrive in
order, and the owner runs them one at a time, so an `async_call` has landed by
the time the next call is answered.

Prefer `async_call`. A change you do not need an answer to costs you nothing to
send, where waiting costs the round trip.

### What comes back is a copy

```ruby
h.async_call {|h| h[:list] = [1] }
got = h[:list]
got << 2          # changes the copy, not the Hash
h[:list]          #=> [1]
```

That is the same bargain ETS makes, and it is what lets the values be mutable at
all. To change one, change it where it lives.

The block is handed the **real Hash**, not a copy and not a proxy, so every Hash
method is there. It cannot escape either, since the block runs on the owner and
anything returned is copied on the way back.

### The block is isolated

It crosses to another Ractor, so `Ractor.shareable_proc` has to accept it: it may
read outer variables that are **never reassigned** anywhere in their scope, and
everything else has to be passed as an argument.

```ruby
h.set(:total, 0)
n = 10
h.async_call {|h| h[:total] += n }         # fine: n is never reassigned
h.async_call(10) {|h, n| h[:total] += n }  # always fine
```

"Never reassigned" is judged from the whole enclosing scope: one later assignment
to `n` makes every block that reads it impossible to isolate.

## Where it sits

| | shareable values, no Ractor | any values, a Ractor of its own |
|---|---|---|
| one value | [`LockVar`](lockvar.md) | |
| a hash | [`LockHash`](lockhash.md) | **`ActorHash`** |
| your own class | | [`ActiveObject`](active_object.md) |

`ActorHash` is an `ActiveObject` with the interface already chosen, and is built
on one. Use `ActiveObject` directly when the state deserves methods of its own.

Part of [ractor-sharing](../README.md).
