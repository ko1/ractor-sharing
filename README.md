# ractor-sharing

Ways for Ractors to share mutable state.

Ractors keep their objects to themselves. What crosses between them is either
frozen or copied, so there is nowhere to put a counter, a registry or a cache
that several Ractors both read and change. Each class here is such a place.

**Start with [`Ractor::TVar`](docs/tvar.md).** It takes one variable or several,
it cannot deadlock, and it is the quickest of these when a variable is fought
over. Move off it only for a reason the others below name.

| | reach for it when | cost |
|---|---|---|
| [`Ractor::TVar`](docs/tvar.md)<br>`Ractor.atomically { a.value += 1 }` | always, unless a row below says otherwise. One variable or a dozen, with no lock order to get wrong | 71 ns |
| [`Ractor::LockVar`](docs/lockvar.md)<br>`lv.update {\|v\| v + 1 }` | the block must run **exactly once**, because it logs, sends, or does anything else a retry would repeat | 118 ns |
| [`Ractor::LockHash`](docs/lockhash.md)<br>`h.synchronize {\|h\| h[k] = v }` | the same, but the keys are not known in advance | 195 ns |
| [`Ractor::ActiveObject`](docs/active_object.md)<br>`sync def add(k, v) = @db[k] = v` | the values will not be frozen, and the state deserves methods of its own | 2.2 µs + a Ractor |
| [`Ractor::ActorHash`](docs/actor_hash.md)<br>`h.async_call {\|h\| h[:hits] += 1 }` | the same, and a plain hash is all the interface you need | 2.0 µs + a Ractor |

Cost is one uncontended operation from a single Ractor on 16 cores; the two at the
bottom also start a Ractor apiece, which runs until the process ends.

The first three hold **shareable** values, so a change replaces a value rather
than modifying it: `lv.update { it.merge(k => v).freeze }`. When your state is a
mutable object you have no intention of freezing, such as a Hash you keep writing
into or an object graph with methods over it, it cannot go in any of them. The last two
are for exactly that: the object stays mutable and unshareable, in a Ractor of
its own, and you send it the calls instead of the data.

```ruby
require "ractor/sharing"        # all of them

require "ractor/tvar"           # or one at a time
require "ractor/lockvar"
require "ractor/lockhash"
require "ractor/active_object"
require "ractor/actor_hash"
```

## Which one

**The default: `TVar`.** One variable or a dozen, and the same code either way:
whatever a transaction changes, the rest of the program sees all of it or none of
it. There is no lock to take in the right order, so two transactions can never
deadlock, and when a variable is genuinely fought over it is the quickest thing
here, because losing a race and retrying beats parking a thread.

```ruby
from, to = Ractor::TVar.new(100), Ractor::TVar.new(0)
Ractor.atomically { from.value -= 10; to.value += 10 }
```

The one thing to hold on to: a transaction that loses a race is **rolled back and
run again**, so its block has to be safe to run twice. Keep it to reading and
writing TVars. Everything below is a reason to leave that behind.

**When the block must run exactly once: `LockVar`.** If the block has a side
effect a retry would repeat, such as writing a line or sending a message, then
waiting for a turn beats retrying. One shareable value, and the
block runs once by construction.

```ruby
counter = Ractor::LockVar.new(0)
4.times.map { Ractor.new(counter) {|c| 1000.times { c.increment } } }.each(&:join)
counter.value #=> 4000
```

**The same, for a hash: `LockHash`.** A registry, a cache, a scoreboard each
worker writes a row of, where the keys are not known in advance. Reads need no
ceremony; writes go inside `synchronize`, and everything one section changes
appears at once. Atomic across its own keys, and only those.

```ruby
board = Ractor::LockHash.new
board.synchronize {|b| b[:worker_1] = 42 }
board.to_h #=> {worker_1: 42}
```

**A mutable object: `ActiveObject`.** When freezing the state is not on the
table, give the object a Ractor of its own. It never leaves; callers send method
calls in, the owner runs them one at a time, and the object goes on being an
ordinary mutable Ruby object.

Know what that costs. Each instance **starts a Ractor**, which lives until the
process ends, since there is no way to stop one, so this is for a handful of
long-lived objects, not for many small ones. And every call from another Ractor
is a message round trip: about **2.0 µs** from a worker Ractor, against
**0.12 µs** for an uncontended `LockVar#update` on the same machine. Calls
to one object are also serialized through its owner, so the object is a
throughput limit as well as a home for the state. If your state does fit in a
shareable value, one of the first three will cost you far less.

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
**A hash whose values will not be frozen: `ActorHash`.** Same shape as
`LockHash`, but the entries live in a Ractor of its own, so they can be anything
and a block changes them in place over there. Reads are questions you ask;
changes are work you send, and you need not wait for them.

```ruby
h = Ractor::ActorHash.new
h.increment(:hits)
h.async_call {|h| (h[:log] ||= []) << line }
h[:log]
```


## Performance

Nanoseconds for one operation, counted across all Ractors, on 16 cores.

| | one Ractor | 16 on one object | 16 on their own | spreading out |
|---|---:|---:|---:|---|
| `TVar#increment` | 60 | **157** | 79 | does not help |
| `LockVar#increment` | 121 | 426 | **16** | 7.6× faster |
| `LockHash#synchronize` | 192 | 628 | 25 | 7.7× faster |
| `ActiveObject` sync method | 2202 | 1380 | 713 | 3.1× faster |
| `ActorHash#call` | 3197 | 2043 | 789 | 4.1× faster |
| no sharing at all | 24 | n/a | 3 | 8× faster |

Three things to read off it. **Spread out, the locks scale as far as the machine
does** and `TVar` does not, because every committing transaction takes one
process-wide lock to allocate its version number. **Fought over, `TVar` wins**,
because losing a race and retrying an operation that small is cheaper than
parking a thread and waking it. **The two that keep a Ractor cost microseconds
either way**, and a Ractor each.

The last row is the machine's own ceiling: 8× is as far as anything here scales.
Called from the main Ractor rather than a worker, the last two cost about 8.9 µs
instead of 2, because that thread has a native thread to itself and waking it is
a syscall.

`benchmark/family.rb` produces this table, and sweeps 1, 2, 4, 8 and 16 Ractors
under both conditions. These numbers are from ruby 4.1.0dev (master 69b49ac7ae)
on 16 cores with the CPU governor fixed at `performance`, one run per cell.

## What is not here

These classes hold state. They are not a way for Ractors to wait for each other.

A Ractor waits in one place, `Ractor::Port#receive`, and that is the design, not
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

Documentation for each class is in [docs/](docs/).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
