# ractor-sharing

Ways for Ractors to share mutable state.

Ractors keep their objects to themselves. What crosses between them is either
frozen or copied, so there is nowhere to put a counter, a registry or a cache
that multiple Ractors can both read and update. Each class here is such a place.

What each one is, in a line:

* **[`Ractor::TVar`](docs/tvar.md)** is a *transactional* variable. Read and
  write as many of them as you like inside one `Ractor.atomically` block, and
  all changes made by that block take effect together or not at all. A block
  that loses a race is rolled back and run again.
* **[`Ractor::LockVar`](docs/lockvar.md)** is a variable behind a *lock*. An
  update waits for its turn, and then its block runs exactly once.
* **[`Ractor::LockHash`](docs/lockhash.md)** is a hash behind one lock. A
  `synchronize` section is atomic across the keys of that hash, and only that hash.
* **[`Ractor::KeyLockHash`](docs/keylockhash.md)** is a hash with one stable
  entry and atomic claim per key: the row lock to LockHash's table lock. Reads
  are lock-free, updates to unrelated keys run in parallel, and nothing is
  atomic across two keys.
* **[`Ractor::ActiveObject`](docs/active_object.md)** is an object that lives in
  a Ractor of its own. It never leaves; callers send it method calls, and the
  owner runs them one at a time.
* **[`Ractor::ActorHash`](docs/actor_hash.md)** is a hash that lives in a Ractor
  of its own. Callers send it blocks to run on it.

**Start with `Ractor::TVar`.** It takes one variable or several, it cannot
deadlock, and it is the quickest of these under contention. Choose another
abstraction only when one of the reasons below applies.

| | reach for it when | read | write |
|---|---|---:|---:|
| [`Ractor::TVar`](docs/tvar.md)<br>`Ractor.atomically { a.value += 1 }` | always, unless a row below says otherwise. One variable or a dozen, with no lock order to get wrong | 80 ns | 348 ns |
| [`Ractor::LockVar`](docs/lockvar.md)<br>`lv.update {\|v\| v + 1 }` | the block must run **exactly once**, because it logs, sends, or does anything else a retry would repeat | 86 ns | 342 ns |
| [`Ractor::LockHash`](docs/lockhash.md)<br>`h.synchronize {\|h\| h[k] = v }` | two or more keys must change together, or a snapshot must be consistent | 119 ns | 443 ns |
| [`Ractor::KeyLockHash`](docs/keylockhash.md)<br>`m.update(k) {\|v\| v + 1 }` | the keys are independent: registries, caches, buckets, idempotency claims. Parallel across keys | 65 ns | 358 ns |
| [`Ractor::ActiveObject`](docs/active_object.md)<br>`sync def add(k, v) = @db[k] = v` | the values will not be frozen, and the state deserves methods of its own | 2.2 µs | 2.7 µs |
| [`Ractor::ActorHash`](docs/actor_hash.md)<br>`h.call {\|h\| h[:hits] += 1 }` | the same, and a plain hash is all the interface you need | 2.2 µs | 2.8 µs |

One uncontended operation from a single Ractor on 16 cores, replacing a frozen
record. The two at the bottom also start a Ractor apiece, which runs until the
process ends; their write is the figure for a `sync` call, and drops to 1.6 µs
and 1.9 µs when sent without waiting for the reply (`async def`, `async_call`).
Contended, the order changes: see [Performance](#performance).

The first four hold **shareable** values -- made shareable for you on the way
in, so no `.freeze` and no `Ractor.make_shareable` of your own -- and a change
replaces a value rather than modifying it: `lv.update { it.merge(k => v) }`. When your state is a mutable
object you intend to keep mutating, such as a Hash you keep writing into or an
object graph with methods over it, storing it there would freeze it. The last
two are for exactly that: the object stays mutable and unshareable, in a Ractor
of its own, and you send it the calls instead of the data.

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
deadlock, and under genuine contention it is the quickest thing
here, because losing a race and retrying beats parking a thread.

```ruby
class Service
  def initialize
    @mode   = Ractor::TVar.new(:maintenance)
    @notice = Ractor::TVar.new("closed for maintenance")
    Ractor.make_shareable(self)   # the TVars already are; this seals the shell
  end

  def open!  = Ractor.atomically { @mode.value = :open; @notice.value = "welcome!" }
  def status = Ractor.atomically { [@mode.value, @notice.value] }   # one snapshot
end

SERVICE = Service.new             # shareable, so a constant every Ractor can use

watchers = 4.times.map do
  Ractor.new do
    mixed = 0
    10_000.times do
      state, text = SERVICE.status
      mixed += 1 if (state == :open) != (text == "welcome!")
    end
    mixed
  end
end

SERVICE.open!

watchers.sum(&:value) #=> 0
```

Forty thousand snapshots taken across the flip, and not one of them caught the
mode and the notice disagreeing. And look at the class: an ordinary one that
makes itself shareable in its own `initialize`, so the instance lives in a
constant and every Ractor just uses it -- the TVars are where the change
lives. Its methods run in whichever Ractor calls them: no owner, no message,
no round trip. That is the pattern to reach for before `ActiveObject` below,
which exists for state that cannot be frozen at all.

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
lock = Ractor::LockVar.new(nil)

claims = %w[ann ben cho dee].map do |name|
  Ractor.new(lock, name) do |lv, me|
    won = false
    lv.update {|holder| holder || (won = true; me) }  # announce here: it runs once
    won
  end
end

claims.map(&:value).count(true) #=> 1
```

Four Ractors race to take the deploy lock; each block runs exactly once, so
exactly one of them believes it won -- with a `TVar` the losing blocks would
have run again, and a side effect in them with it.

**Keys that change together: `LockHash`.** The everyday shape is a hash that
holds an index into itself: a session store maps each token to its user *and*
each user to their tokens, because "log out everywhere" needs the list. Login
writes two keys; revocation deletes many. Each is one `synchronize`, because
the gap is a security hole: revoked one by one, a racing request still
authenticates with a not-yet-deleted token.

```ruby
sessions = Ractor::LockHash.new

logins = %w[ann ben].flat_map do |user|
  2.times.map do |device|
    Ractor.new(sessions, user, "sid-#{user}-#{device}") do |s, u, sid|
      s.synchronize {|h| h[sid] = u; h[u] = (h[u] || []) + [sid] }
    end
  end
end
logins.each(&:join)

sessions.synchronize do |h|                    # ann logs out everywhere
  (h["ann"] || []).each {|sid| h.delete(sid) }
  h.delete("ann")
end

sessions["sid-ann-0"] #=> nil
sessions["sid-ben-1"] #=> "ben"
```

Reads need no ceremony; writes go inside `synchronize`, and everything one
section changes appears at once -- atomic across its own keys, and only that
hash, with `to_h` a snapshot no write can tear.

**Independent keys, in parallel: `KeyLockHash`.** A registry, a cache, a
scoreboard where each worker owns its row: hashes whose keys never change
together. There the whole-hash lock above is paying for atomicity nobody asked
for, with unrelated clients waiting in one queue. `KeyLockHash` claims a stable
entry per key, and the everyday shape is a get-or-create cache:

```ruby
cache = Ractor::KeyLockHash.new

readers = 4.times.map do
  Ractor.new(cache) do |c|
    renders = 0
    render = ->(page) { renders += 1; "<p>page #{page}</p>" }   # the expensive part

    100.times do |i|
      page = i % 10
      c.update("page-#{page}") {|html| html || render.(page) }
    end
    renders
  end
end

readers.sum(&:value) #=> 10
```

Four hundred fetches over ten pages, and the render ran exactly ten times.
`update` owns that entry's claim while the block runs, so simultaneous misses
on one page wait for the first -- and waiting is correct here, because everyone
waiting would have rendered the same page themselves: the system does the work
once instead of eight times, and a miss on a *different* page never queues at
all. (That is the one shape where a long block is the right trade; the rule
and its price are in [the docs](docs/keylockhash.md).) A per-client tally is one
`hits.increment(client)`, and check-and-claim is `update` with `:claimed` in
it.


**A mutable object: `ActiveObject`.** When freezing the state is not on the
table, give the object a Ractor of its own. It never leaves; callers send method
calls in, the owner runs them one at a time, and the object goes on being an
ordinary mutable Ruby object.

Know what that costs. Each instance **starts a Ractor**, which lives until the
process ends, since there is no way to stop one, so this is for a handful of
long-lived objects, not for many small ones. And every call from another Ractor
is a message round trip: a `sync` call is about **2.6 µs** from a worker Ractor,
against **0.35 µs** for an uncontended `LockVar#update` on the same machine. An
`async` call does not wait for the reply and costs about **1.6 µs**. Calls
to one object are also serialized through its owner, so the object is a
throughput limit as well as a home for the state. If your state does fit in a
shareable value, one of the first three will cost you far less.

```ruby
class People < Ractor::ActiveObject
  def initialize = @db = {}
  async def add(name, age) = @db[name] = age   # fire and forget
  sync  def find(name) = @db[name]             # a question: waits for the answer
end

people = People.new
people.add("ada", 36)
people.add("lin", 28)

people.find("ada") #=> 36
Ractor.new(people) {|p| p.find("lin") }.value #=> 28
```

`People.new` returns a shareable proxy: hand it to any Ractor and the calls
all funnel to the one owner, where `@db` stays an ordinary mutable Hash.

**A hash whose values will not be frozen: `ActorHash`.** Same shape as
`LockHash`, but the entries live in a Ractor of its own, so they can be anything
and a block changes them in place over there. Reads are questions you ask;
changes are work you send, and you need not wait for them.

```ruby
h = Ractor::ActorHash.new

loggers = 3.times.map do |i|
  Ractor.new(h, i) do |hash, id|
    hash.increment(:hits)
    hash.async_call(id) {|x, me| (x[:log] ||= []) << me }   # mutated in place, over there
  end
end
loggers.each(&:join)

h[:hits] #=> 3
h.call {|x| x[:log].sort } #=> [0, 1, 2]
```

The log is a plain mutable Array that never leaves the owner; the blocks go to
it, not the other way around.

Two signs you picked the wrong one. Reaching for two `LockVar`s at once is
refused, with a message pointing here: that is the sign you wanted a `TVar`.
Finding yourself freezing a copy of a collection on every update is the sign you
wanted an `ActiveObject`.

### In database terms

If you think in database vocabulary, the first four unbundle what a database
ships as one engine:

| in a database | here |
|---|---|
| an MVCC read, taking no lock | `TVar#value` outside a transaction |
| a serializable transaction, retried on conflict | `Ractor.atomically` |
| a row lock | `KeyLockHash` -- sold separately: no transaction spans two of them |
| a table lock | `LockHash#synchronize` |
| the deadlock detector | not shipped: a second lock raises `Ractor::NestedLockError` at the door |

Databases can default to row locks because a transaction manager acquires many
of them and a deadlock detector cleans up when that cycles. There is no
detector here, so the second lock is refused instead, and work that spans keys
goes to the table lock or to the transactions.

One thing no detector catches, there or here: taking too **few** locks. A
deadlock is a cycle in who-waits-for-whom; locking one key, releasing it and
then locking another produces no wait and no cycle, just an invariant quietly
broken -- databases only catch that shape at serializable, because a declared
transaction tells them what was supposed to be atomic. The declaration is the
protection: keys that must agree go inside one `synchronize` or one
`Ractor.atomically`, and no runtime is going to notice for you.


## Performance

The workload is one shared record, a frozen `{status:, seq:}`: a **read** takes it
out, a **write** puts a new frozen one in its place. Nanoseconds for one
operation, counted across all Ractors, on 16 cores.

### Reading

| | one Ractor (ns) | 16 on one object (ns) | 16 on their own (ns) |
|---|---:|---:|---:|
| `TVar#value` | 80 | **9** | 9 |
| `KeyLockHash#[]` | 65 | **12** | 14 |
| `LockVar#value` | 86 | 328 | 10 |
| `LockHash#[]` | 119 | 421 | 19 |
| `ActiveObject` sync method | 2172 | 1421 | 741 |
| `ActorHash#[]` | 2211 | 1399 | 728 |
| no sharing at all | 65 | n/a | 8 |

**Reads of a shared object scale on the two lock-free readers, `TVar` and
`KeyLockHash`, and queue on the two locks.** A `TVar` read outside a transaction
takes nothing, and a `KeyLockHash` read probes an atomically published bins
generation and loads its stable entry without a lock, so sixteen Ractors reading one shared object
cost about what one does -- 9 and 12 ns. `LockVar#value` and `LockHash#[]` take
the lock, so those sixteen readers stand in a queue: 328 and 421 ns against 10
and 19. Give each Ractor its own object and every one of them scales to the
machine's limit.

### Writing

| | one Ractor (ns) | 16 on one object (ns) | 16 on their own (ns) |
|---|---:|---:|---:|
| `TVar` transaction | 348 | **758** | 107 |
| `LockVar#update` | 342 | 1072 | **46** |
| `LockHash#synchronize` | 443 | 1240 | 65 |
| `KeyLockHash#update` | 358 | 1202 | 52 |
| `ActiveObject` async method | 1525 | 742 | 179 |
| `ActiveObject` sync method | 2701 | 1590 | 748 |
| `ActorHash#async_call` | 1607 | 994 | 179 |
| `ActorHash#call` | 2771 | 1735 | 746 |
| no sharing at all | 136 | n/a | 18 |

**Under contention, nothing scales and `TVar` stays ahead**, roughly 1.5×,
because losing a race and running a short block again is cheaper than parking a
thread and waking it, and a transaction that keeps losing backs off, about 100 ns
per consecutive loss, spinning rather than sleeping, before running again. Every
cell is the median of three runs; the `TVar` contended-write cell is the volatile
one, swinging between sweeps (500 to 870 ns across sessions).
**Spread out, the locks scale as far as the machine does and `TVar` does not**:
about 7× for `LockVar` against 3.3×, because every committing transaction takes
one process wide lock to allocate its version number. **Not waiting for the reply
is worth about 4× when the objects are spread out** on the two classes that keep
a Ractor (16 on their own, sync against async above); on one shared object the
serialisation at the owner leaves it about 2×, and from a single caller it is
about 1.7×.

`KeyLockHash` writes are where its shape shows -- its reads already scaled with
`TVar` in the reading table. On one shared key it is one lock like the rest, but
over **one shared map with a key per Ractor** the per-entry claims scale where
`LockHash`'s single table lock does not: 45 ns against `LockHash`'s 568 at four
Ractors, 22 against 593 at sixteen.

The `no sharing at all` row is the machine's own ceiling: about 8× is as far as
anything here scales. Called from the main Ractor rather than a worker, the two
Ractor backed classes cost about 8.9 µs instead of 2.6, because that thread has a
native thread to itself and waking it is a syscall.

### Not increment

`TVar#increment` and `LockVar#increment` each take a fast path that adds two
Fixnums without running any Ruby, so a benchmark built on `increment` measures
that path rather than the class. It gets a table of its own:

| | one Ractor (ns) | 16 on one object (ns) | 16 on their own (ns) |
|---|---:|---:|---:|
| `LockVar#increment` | 74 | 361 | **8** |
| `TVar#increment` | 80 | **145** | 75 |
| `KeyLockHash#increment` | 140 | 544 | 20 |

One hot counter belongs in a `LockVar` (or a `TVar`, contended); counters that
spread over keys belong in the `KeyLockHash`, which pays the hash and the guard
per call and scales across its keys like everything else it does.

`benchmark/family.rb` produces all of these, sweeping 1, 2, 4, 8 and 16 Ractors
over read, write and a 9:1 mix, under both conditions. Every worker reports ready
before the clock starts, and every run is checked afterwards against the number
of writes that went in, so a lost update cannot report itself as a fast run.
These numbers are from ruby 4.1.0dev (master 69b49ac7ae) on 16 cores with the CPU
governor fixed at `performance`.

**Each cell is the median of three runs** (`REPS=3`), and how much to trust a
small difference depends on the row. Between two independent sweeps the
`TVar`, `LockVar` and `LockHash` cells moved by 0% to 10%, so their comparisons
hold. The two async rows moved by 12% to 23%, which is why the claim above is 3×
to 4× and not a figure with a decimal in it.

## What is not here

These classes hold state. They are not a way for Ractors to wait for each other.

A Ractor waits in one place, `Ractor::Port#receive`, and that is the design, not
an accident. Waiting for another Ractor to produce something, hand work over or
reach a point is a conversation between them, and it is held in messages. So
there is no queue here that several Ractors take work from, no barrier, no
semaphore: those would be a second place to wait, and a rendezvous dressed up as
a data structure.

When one of those shapes is what you want, it is usually the family and the
Port composing: [examples/17_pubsub.rb](examples/17_pubsub.rb) is pub/sub in
thirty lines, the subscription book as state and the delivery as ports.

The one wait they make you do is for a lock, and even that is a `receive`: a
thread that cannot take a lock parks on a `Ractor::Port` of its own until the
holder sends it a wakeup. (Inside the extensions there are native mutexes, held
for a few instructions and never across Ruby code, and `ActiveObject` waits on
`Ractor.select` while its owner starts. Neither is a place your program waits.)

## Requirements

Ruby 4.0 or later (`Ractor::Port`, and Ractors that are worth using).

## Development

```
rake                         # compile both extensions and run the normal tests
rake stress:keylockhash      # opt-in resize/contention/GC stress test
```

The stress test is deliberately excluded from the normal `rake` task so it does
not slow CI. Tune it with `KLH_STRESS_SEEDS`, `KLH_STRESS_WORKERS`,
`KLH_STRESS_ROUNDS`, `KLH_STRESS_GC_ROUNDS`, `KLH_STRESS_COMPACT=0`, and
`KLH_STRESS_TIMEOUT`. For example:

```
KLH_STRESS_WORKERS=16 KLH_STRESS_ROUNDS=10000 \
  KLH_STRESS_GC_ROUNDS=250 rake stress:keylockhash
```

`KeyLockHash` retains an append-only entry for every distinct key it has seen,
including deleted keys. Use `benchmark/keylockhash_churn.rb` to measure that
time/space tradeoff; compaction of those entries is not implemented yet.

Documentation for each class is in [docs/](docs/), and ten runnable,
self-checking examples are in [examples/](examples/).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
