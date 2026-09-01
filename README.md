# ractor-sharing

Ways for Ractors to share mutable state.

Ractors keep their objects to themselves. What crosses between them is either
frozen or copied, so there is nowhere to put a counter, a registry or a cache
that several Ractors both read and change. Each class here is such a place.

What each one is, in a line:

* **[`Ractor::TVar`](docs/tvar.md)** is a *transactional* variable. Read and
  write any number of them inside one `Ractor.atomically` block, and everything
  that block changed takes effect together or not at all. A block that loses a
  race is rolled back and run again.
* **[`Ractor::LockVar`](docs/lockvar.md)** is a variable behind a *lock*. An
  update waits for its turn, and then its block runs exactly once.
* **[`Ractor::LockHash`](docs/lockhash.md)** is a hash behind one lock. A
  `synchronize` section is atomic across the keys of that hash, and only those.
* **[`Ractor::ActiveObject`](docs/active_object.md)** is an object that lives in
  a Ractor of its own. It never leaves; callers send it method calls, and the
  owner runs them one at a time.
* **[`Ractor::ActorHash`](docs/actor_hash.md)** is a hash that lives in a Ractor
  of its own. Callers send it blocks to run on it.

**Start with `Ractor::TVar`.** It takes one variable or several, it cannot
deadlock, and it is the quickest of these when a variable is fought over. Move
off it only for a reason the others below name.

| | reach for it when | read | write |
|---|---|---:|---:|
| [`Ractor::TVar`](docs/tvar.md)<br>`Ractor.atomically { a.value += 1 }` | always, unless a row below says otherwise. One variable or a dozen, with no lock order to get wrong | 65 ns | 344 ns |
| [`Ractor::LockVar`](docs/lockvar.md)<br>`lv.update {\|v\| v + 1 }` | the block must run **exactly once**, because it logs, sends, or does anything else a retry would repeat | 74 ns | 367 ns |
| [`Ractor::LockHash`](docs/lockhash.md)<br>`h.synchronize {\|h\| h[k] = v }` | the same, but the keys are not known in advance | 134 ns | 452 ns |
| [`Ractor::ActiveObject`](docs/active_object.md)<br>`sync def add(k, v) = @db[k] = v` | the values will not be frozen, and the state deserves methods of its own | 2.1 µs | 2.5 µs |
| [`Ractor::ActorHash`](docs/actor_hash.md)<br>`h.call {\|h\| h[:hits] += 1 }` | the same, and a plain hash is all the interface you need | 2.2 µs | 2.8 µs |

One uncontended operation from a single Ractor on 16 cores, replacing a frozen
record. The two at the bottom also start a Ractor apiece, which runs until the
process ends; their write is the figure for a `sync` call, and drops to 1.5 µs
and 1.7 µs when sent without waiting for the reply (`async def`, `async_call`).
Contended, the order changes: see [Performance](#performance).

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
writing TVars.

That retry is also what contention costs it. With sixteen Ractors on one variable
a minimal block runs about 1.8 times per completed update, which is cheap enough
that `TVar` is still the quickest thing here. The factor climbs with the length
of the block, though: a few microseconds of work in there and it runs closer to
five times, and most of the machine is doing work that gets thrown away. A
variable that is both hot and not trivial to update is the case for `LockVar`
below, which waits its turn and runs the block once.

Everything below is a reason to leave `TVar` behind.

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
is a message round trip: a `sync` call is about **2.5 µs** from a worker Ractor,
against **0.37 µs** for an uncontended `LockVar#update` on the same machine. An
`async` call does not wait for the reply and costs about **1.5 µs**. Calls
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

**A hash whose values will not be frozen: `ActorHash`.** Same shape as
`LockHash`, but the entries live in a Ractor of its own, so they can be anything
and a block changes them in place over there. Reads are questions you ask;
changes are work you send, and you need not wait for them.

```ruby
h = Ractor::ActorHash.new
h.increment(:hits)
h.async_call {|h| (h[:log] ||= []) << "a line" }
h[:log]
```

Two signs you picked the wrong one. Reaching for two `LockVar`s at once is
refused, with a message pointing here: that is the sign you wanted a `TVar`.
Finding yourself freezing a copy of a collection on every update is the sign you
wanted an `ActiveObject`.


## Performance

The workload is one shared record, a frozen `{status:, seq:}`: a **read** takes it
out, a **write** puts a new frozen one in its place. Nanoseconds for one
operation, counted across all Ractors, on 16 cores.

### Reading

| | one Ractor (ns) | 16 on one object (ns) | 16 on their own (ns) |
|---|---:|---:|---:|
| `TVar#value` | 65 | **9** | 9 |
| `LockVar#value` | 74 | 339 | 10 |
| `LockHash#[]` | 134 | 480 | 17 |
| `ActiveObject` sync method | 2146 | 1382 | 730 |
| `ActorHash#[]` | 2205 | 1463 | 773 |
| no sharing at all | 65 | n/a | 8 |

**Reads of a shared object scale on `TVar` and do not on the two locks.** A
`TVar` read outside a transaction takes nothing, so sixteen Ractors reading one
`TVar` cost the same as sixteen reading their own. `LockVar#value` and
`LockHash#[]` take the lock, so those sixteen readers stand in a queue: 339 ns
against 9. Give each Ractor its own object and every one of them scales to the
machine's limit.

### Writing

| | one Ractor (ns) | 16 on one object (ns) | 16 on their own (ns) |
|---|---:|---:|---:|
| `TVar` transaction | 344 | **872** | 108 |
| `LockVar#update` | 367 | 1157 | **52** |
| `LockHash#synchronize` | 452 | 1265 | 90 |
| `ActiveObject` async method | 1472 | 731 | 226 |
| `ActiveObject` sync method | 2489 | 1650 | 748 |
| `ActorHash#async_call` | 1746 | 997 | 191 |
| `ActorHash#call` | 2834 | 1746 | 740 |
| no sharing at all | 138 | n/a | 21 |

**Fought over, nothing scales and `TVar` is ahead**, because losing a race and
running a short block again is cheaper than parking a thread and waking it.
**Spread out, the locks scale as far as the machine does and `TVar` does not**:
7.1× for `LockVar` against 3.2×, because every committing transaction takes one
process wide lock to allocate its version number. **Not waiting for the reply is
worth 3× to 9×** on the two classes that keep a Ractor, and that is the whole
difference between their sync and async rows.

The `no sharing at all` row is the machine's own ceiling: about 8× is as far as
anything here scales. Called from the main Ractor rather than a worker, the two
Ractor backed classes cost about 8.9 µs instead of 2.2, because that thread has a
native thread to itself and waking it is a syscall.

### Not increment

`TVar#increment` and `LockVar#increment` each take a fast path that adds two
Fixnums without running any Ruby, so a benchmark built on `increment` measures
that path rather than the class. It gets a table of its own:

| | one Ractor (ns) | 16 on one object (ns) | 16 on their own (ns) |
|---|---:|---:|---:|
| `LockVar#increment` | 84 | 342 | **9** |
| `TVar#increment` | 78 | **146** | 77 |

`benchmark/family.rb` produces all of these, sweeping 1, 2, 4, 8 and 16 Ractors
over read, write and a 9:1 mix, under both conditions. Every worker reports ready
before the clock starts, and every run is checked afterwards against the number
of writes that went in, so a lost update cannot report itself as a fast run.
These numbers are from ruby 4.1.0dev (master 69b49ac7ae) on 16 cores with the CPU
governor fixed at `performance`, one run per cell.

## What is not here

These classes hold state. They are not a way for Ractors to wait for each other.

A Ractor waits in one place, `Ractor::Port#receive`, and that is the design, not
an accident. Waiting for another Ractor to produce something, hand work over or
reach a point is a conversation between them, and it is held in messages. So
there is no queue here that several Ractors take work from, no barrier, no
semaphore: those would be a second place to wait, and a rendezvous dressed up as
a data structure.

The one wait they make you do is for a lock, and even that is a `receive`: a
thread that cannot take a lock parks on a `Ractor::Port` of its own until the
holder sends it a wakeup. (Inside the extensions there are native mutexes, held
for a few instructions and never across Ruby code, and `ActiveObject` waits on
`Ractor.select` while its owner starts. Neither is a place your program waits.)

## Requirements

Ruby 4.0 or later (`Ractor::Port`, and Ractors that are worth using).

## Development

```
rake            # compile both extensions and run every test
```

Documentation for each class is in [docs/](docs/).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
