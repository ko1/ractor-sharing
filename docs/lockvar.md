# Ractor::LockVar

**One** variable that Ractors can share. It holds one shareable object; any
Ractor can read it, and any Ractor can replace what is in it, one at a time.
Several variables that have to change together are `Ractor::TVar`'s job, and a
whole hash of them is [`Ractor::LockHash`](lockhash.md)'s.

```ruby
require "ractor/lockvar"

counter = Ractor::LockVar.new(0)

rs = 4.times.map do
  Ractor.new(counter) do |c|
    1000.times { c.update {|n| n + 1 } }
  end
end
rs.each(&:join)

p counter.value #=> 4000
```

## API

```ruby
lv = Ractor::LockVar.new(initial = nil)

lv.value               # read, under the lock -- a snapshot, never an input to update
lv.update {|v| new_v } # replace the value, under the lock; returns new_v
lv.increment(n = 1)    # add n under the lock, as update {|v| v + n } would
lv.inspect
```

A variable, not a lock: there is no lock, unlock, or owner query. `value` and
`update` are the whole of it, and `increment` is there because a counter is what
a shared variable most often is.

### The value must be shareable

A LockVar holds one **shareable** object, and so does everything you store into
it. Anything else raises `ArgumentError`:

```ruby
Ractor::LockVar.new({})            # => ArgumentError: only shareable object are allowed
lv.update { [1, 2] }               # => ArgumentError
lv.update { [1, 2].freeze }        # fine
lv.update { {a: 1}.freeze }        # fine
```

That is what makes a LockVar safe to hand to any Ractor: it is frozen and
shareable itself, and the value inside it is too, so nothing reachable through it
can be mutated behind the lock's back. It also means an update replaces the value
rather than modifying it: `lv.update { it.merge(k => v).freeze }`, not
`lv.value[k] = v`.

A rejected value leaves the variable as it was.

### Reads and updates

Both take the lock, so an update's **whole block** is atomic as far as readers
are concerned, not just its final store. That is what an update block needs when
it makes anything else observable:

```ruby
lv = Ractor::LockVar.new(0)
lv.update {|v| $last = v; v + 1 }   # every reader sees lv.value > $last
```

Blind assignment is `lv.update { x }` (the block just ignores the old value).
There is no `value=`: an unlocked write would silently discard a concurrent
`update` that had already read the old value.

Note that the block's result *is* the new value, so a block that forgets to
return it clears the variable: `lv.update {|v| puts v }` stores `nil`.

`increment` is there because adding to a number is the most common update of all;
it is the block form with the block written for you, and behaves the same way in
every respect, including refusing to store a sum that is not shareable.

## Read-modify-write belongs inside the block

Any new value computed from the current one has to be computed inside `update`,
from the value the block is given. Reading outside and writing inside is broken:
another update lands in between, and yours discards it. Counting is only the
smallest example. The same goes for appending to a frozen array, merging into a
frozen hash, clamping, toggling, anything that reads before it writes.

```ruby
# WRONG
v = lv.value
lv.update { v + 1 }

h = lv.value
lv.update { h.merge(key => 1).freeze }
```

```ruby
# RIGHT
lv = Ractor::LockVar.new(0)
lv.update { it + 1 }

h = Ractor::LockVar.new({}.freeze)
h.update { it.merge(key: 1).freeze }
```

Four Ractors incrementing 500 times each:

```
wrong: 829 / 2000   (1171 updates lost)
right: 2000 / 2000
```

`value` is for looking: a snapshot, true when it was taken and possibly stale by
the time you use it. **Never feed it back into `update`.**

Nothing in the library can catch this for you, so the warning is the whole
defence.

## One variable, and how that differs from TVar

The unit here is a single variable. That is the whole distinction between this
and its neighbour, not optimistic versus pessimistic, which is only how each one
happens to be built.

| | `Ractor::LockVar` | [`Ractor::TVar`](https://github.com/ko1/ractor-tvar) |
|---|---|---|
| synchronizes | one variable | several variables together |
| written as | `lv.update {\|v\| ... }` | `Ractor.atomically { ... }` |
| on conflict | waits its turn | rolls back and runs the block again |
| the block runs | exactly once | as many times as it takes |
| so the block may | have side effects | only compute |
| lock ordering | refused: one variable at a time | not a question |

A transaction only starts to mean something once there is a second variable, so
for one variable there is nothing to express beyond a read-modify-write, which
is why reading and updating are all there is to it.

The row that decides most cases is the rollback. A `TVar` transaction that loses
a race is discarded and run again, so its block has to be safe to run twice:
anything it did that was not a `TVar` write has already happened and will happen
again. A `LockVar` update waits for its turn instead, and then runs once.

```ruby
$log = []
lv = Ractor::LockVar.new(0)
lv.update {|v| $log << v; v + 1 }   # logs exactly once
```

Touching another LockVar from inside an update is refused:

```ruby
a = Ractor::LockVar.new(1)
b = Ractor::LockVar.new(2)
a.update {|v| b.value }
# => Ractor::NestedLockError:
#    already inside another Ractor::LockVar;
#    use Ractor::TVar to change several of them together
```

Lock ordering is where locking goes wrong, and refusing the first nesting turns a
rare production deadlock into a deterministic error. Reaching for a second
variable is the sign that you wanted a transaction: `Ractor::TVar` logs reads and
writes and retries on conflict, so it needs no lock order at all.

No LockVar can be touched from inside an update, its own included. The block is
handed the value it needs, and a nested update's write would be discarded by the
outer block's result anyway. The holder is tracked per **thread**.

## Keep the block short

The block holds the lock while it runs, so everything else waiting on this
variable waits for it. Compute the new value and nothing more: no IO, no waiting
on anything, no calling out to code that might. This is not a `LockVar`
restriction so much as the rule for any critical section, and `TVar` wants the
same thing for its own reason: a transaction is validated against the version it
read when it started, so a long block is a long window for somebody else to
invalidate it.

## Performance

The workload is one shared value, a frozen `{status:, seq:}` record: a **read**
takes it out, an **update** puts a new frozen one in its place. Numbers are **ns
per completed operation across all Ractors**, so one that halves when the Ractors
double means it scaled. Measured on 16 cores with the CPU governor fixed at
`performance`, on ruby 4.1.0dev; `benchmark/family.rb` runs the same comparison
and checks after every run that no update was lost.

### Reading

```ruby
n.times.map {|i| Ractor.new(vars[i]) {|v| K.times { v.value } } }.each(&:join)
```

| Ractors | shared `LockVar#value` (ns) | shared `TVar#value` (ns) | own `LockVar#value` (ns) | own `TVar#value` (ns) |
|---:|---:|---:|---:|---:|
| 1 | 93 | 66 | 74 | 65 |
| 2 | 125 | 74 | 44 | 39 |
| 4 | 206 | 21 | 30 | 24 |
| 8 | 348 | 15 | 18 | 16 |
| 16 | 339 | 9 | 10 | 9 |

**A shared `LockVar` does not scale for reading, and this is the number to know
before choosing it.** `#value` takes the lock, so sixteen Ractors reading one
variable stand in a queue and the read costs 339 ns instead of 10. `TVar#value`
outside a transaction takes nothing, so it reads the same whether the variable is
shared or not. Give each Ractor a variable of its own and both scale to the
machine's limit.

What the lock buys is the guarantee in *Reads and updates* above: a reader waits
for an update in flight, so an update block is atomic to readers and not just its
final store. If your load is read heavy and shared, that guarantee is expensive.

### Updating

```ruby
v.update {|rec| { status: rec[:status], seq: rec[:seq] + 1 }.freeze }
```

| Ractors | shared `LockVar#update` (ns) | shared `TVar` `atomically` (ns) | own `LockVar#update` (ns) | own `TVar` `atomically` (ns) |
|---:|---:|---:|---:|---:|
| 1 | 410 | 331 | 367 | 344 |
| 2 | 861 | 348 | 226 | 214 |
| 4 | 1036 | 438 | 108 | 114 |
| 8 | 1109 | 487 | 82 | 104 |
| 16 | 1157 | 872 | 52 | 108 |

**Fought over, neither scales and `TVar` is ahead**, because the loser of a race
retries a short block where `LockVar` parks the thread and wakes it through a
port, which costs more than the block did. The gap closes at sixteen, where
`TVar` spends more of its time on work it discards.

**Spread out, `LockVar` scales and `TVar` does not**: 367 ns down to 52 is 7.1×,
against 3.2× for `TVar`. Every committing transaction takes one process wide lock
to allocate the next version number, whichever variable it touched, and that lock
is the ceiling.

**Do not choose `LockVar` for speed on a contended variable.** How much any of
this matters depends on how often your variable is actually contended and how
much of your load is reads, which are properties of your program rather than of
either class, so measure yours. What `LockVar` gives you regardless is that the
block runs once.

### Not increment

`LockVar#increment` and `TVar#increment` each take a fast path that adds two
Fixnums without running any Ruby, so they are not a measurement of either class:
84 ns and 78 ns for one Ractor on its own variable, 342 ns and 146 ns for sixteen
on one.

## Implementation notes

* The lock state is protected by a native mutex that is held for a few
  instructions only and **never across Ruby code**, so a waiter can never keep
  another Ractor from reaching a GC safepoint.
* A thread that has to wait parks on a `Ractor::Port` of its own rather than on a
  condition variable. `Port#receive` goes through the VM scheduler, so the wait
  **rides the M:N scheduler** (enabled by default on non-main Ractors) and stays
  interruptible: `Thread#kill` on a waiter works and leaves the lock untouched.
* An uncontended `update` touches the native mutex only: no Port is created and
  no message is sent.
* `update` and `value` are written in C so that no interrupt can be delivered
  between taking the lock and arming the `ensure` that releases it. (With the
  block form written in Ruby, a `Thread#kill` landing in that window stranded the
  lock forever; it reproduced within a couple of iterations.)
* Only the first waiter is woken, and waiters stay queued until they wake by
  themselves, so a wakeup lost to an interrupt is retried by the next release; a
  waiter that leaves without taking the lock passes the wakeup on. A waiter whose
  Ractor has ended has a closed port, so the wakeup is skipped and the next
  waiter is tried instead.
* Acquisition is **not FIFO**: a thread may barge ahead of queued waiters.
* `inspect` never takes the lock, so it neither blocks nor raises.

Part of [ractor-sharing](../README.md).
