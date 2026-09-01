# ractor-sharing

Ways for Ractors to share mutable state.

Ractors keep their objects to themselves. What crosses between them is either
frozen or copied, so there is nowhere to put a counter, a registry or a cache
that several Ractors both read and change. Each class here is such a place.

What picks one is the state you have:

| | holds | you write |
|---|---|---|
| [`Ractor::LockVar`](docs/lockvar.md) | one shareable value | `lv.update {\|v\| v + 1 }` |
| [`Ractor::LockHash`](docs/lockhash.md) | a hash of shareable values, atomic across its own keys | `h.synchronize {\|h\| h[k] = v }` |
| [`Ractor::TVar`](docs/tvar.md) | several shareable values, changed together | `Ractor.atomically { a.value += 1; b.value -= 1 }` |
| [`Ractor::ActorHash`](docs/actor_hash.md) | a hash of anything, kept by a Ractor | `h.async_call {\|h\| h[:hits] += 1 }` |
| [`Ractor::ActiveObject`](docs/active_object.md) | a mutable object, kept unshareable | `sync def add(k, v) = @db[k] = v` |

The first two hold **shareable** values, so an update replaces the value rather
than modifying it: `lv.update { it.merge(k => v).freeze }`. When your state is a
mutable object you have no intention of freezing — a Hash you keep writing into,
an object graph with methods over it — it cannot go in either of them.
`ActiveObject` is for exactly that: the object stays mutable and unshareable, in
a Ractor of its own, and you send it the calls instead of the data.

```ruby
require "ractor/sharing"   # or one at a time: "ractor/lockvar", "ractor/tvar", "ractor/active_object"
```

## Which one

**One variable — `LockVar`.** A counter, a flag, the current configuration.
`update` reads it, runs your block and writes the result back, and your block
runs exactly once, so it may have side effects.

```ruby
counter = Ractor::LockVar.new(0)
4.times.map { Ractor.new(counter) {|c| 1000.times { c.increment } } }.each(&:join)
counter.value #=> 4000
```

**A hash — `LockHash`.** A registry, a cache, a scoreboard each worker writes a
row of. Reads need no ceremony; writes go inside `synchronize`, and everything
one section changes appears at once. Atomic across its own keys, and only those.

```ruby
board = Ractor::LockHash.new
board.synchronize {|b| b[:me] = score }
board.to_h
```

**Several variables that must agree — `TVar`.** Moving a balance from one
account to another: either both variables change or neither does. A transaction
that loses a race is rolled back and run again, so its block must be safe to run
twice.

```ruby
from, to = Ractor::TVar.new(100), Ractor::TVar.new(0)
Ractor.atomically { from.value -= 10; to.value += 10 }
```

**A hash whose values will not be frozen — `ActorHash`.** Same shape as
`LockHash`, but the entries live in a Ractor of its own, so they can be anything
and a block changes them in place over there. Reads are questions you ask;
changes are work you send, and you need not wait for them.

```ruby
h = Ractor::ActorHash.new
h.increment(:hits)
h.async_call {|h| (h[:log] ||= []) << line }
h[:log]
```

**A mutable object — `ActiveObject`.** When freezing the state is not on the
table, give the object a Ractor of its own. It never leaves; callers send method
calls in, the owner runs them one at a time, and the object goes on being an
ordinary mutable Ruby object.

Know what that costs. Each instance **starts a Ractor**, which lives until the
process ends — there is no way to stop one — so this is for a handful of
long-lived objects, not for many small ones. And every call from another Ractor
is a message round trip: about **8.7 µs**, against **0.12 µs** for an
uncontended `LockVar#update` on the same machine, some seventy times more. Calls
to one object are also serialized through its owner, so the object is a
throughput limit as well as a home for the state. If your state does fit in a
shareable value, one of the other two will cost you far less.

```ruby
class People < Ractor::ActiveObject
  def initialize = @db = {}
  async def add(name, age) = @db[name] = age
  sync  def find(name) = @db[name]
end
```

Reaching for two `LockVar`s at once is refused, with a message pointing here:
that is the sign you wanted a `TVar`. Finding yourself freezing a copy of a
collection on every update is the sign you wanted an `ActiveObject`.

## What is not here

These classes hold state. They are not a way for Ractors to wait for each other.

A Ractor waits in one place — `Ractor::Port#receive` — and that is the design, not
an accident. Waiting for another Ractor to produce something, hand work over or
reach a point is a conversation between them, and it is held in messages. So
there is no queue here that several Ractors take work from, no barrier, no
semaphore: those would be a second place to wait, and a rendezvous dressed up as
a data structure.

The one wait these classes do is for a lock, and even that is a `receive`: a
thread that cannot take a lock parks on a `Ractor::Port` of its own until the
holder sends it a wakeup.

## Requirements

Ruby 4.0 or later (`Ractor::Port`, and Ractors that are worth using).

## Development

```
rake            # compile both extensions and run every test
```

Documentation for each class is in [docs/](docs/); `docs/active_object-design.md`
is the design note `ActiveObject` was built from.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
