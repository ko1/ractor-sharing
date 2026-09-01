# Ractor::LockVar

**One** variable that Ractors can share. It holds one shareable object; any
Ractor can read it, and any Ractor can replace what is in it, one at a time.
Several variables that have to change together are `Ractor::TVar`'s job, not
this one's.

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

The whole API is two methods:

```ruby
lv = Ractor::LockVar.new(initial = nil)

lv.value               # read, under the lock -- a snapshot, never an input to update
lv.update {|v| new_v } # replace the value, under the lock; returns new_v
lv.increment(n = 1)    # the same as update {|v| v + n }
```

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
rather than modifying it — `lv.update { it.merge(k => v).freeze }`, not
`lv.value[k] = v`.

A rejected value leaves the variable as it was.

### Reads and updates

Both take the lock, so an update's **whole block** is atomic as far as readers
are concerned — not just its final store. That is what an update block needs when
it makes anything else observable:

```ruby
lv.update {|v| $last = v; v + 1 }   # every reader sees lv.value > $last
```

Blind assignment is `lv.update { x }` (the block just ignores the old value).
There is no `value=`: an unlocked write would silently discard a concurrent
`update` that had already read the old value.

Note that the block's result *is* the new value, so a block that forgets to
return it clears the variable — `lv.update {|v| puts v }` stores `nil`.

`increment` is there because adding to a number is the most common update of all;
it is the block form with the block written for you, and behaves the same way in
every respect — including refusing to store a sum that is not shareable.

## Read-modify-write belongs inside the block

Any new value computed from the current one has to be computed inside `update`,
from the value the block is given. Reading outside and writing inside is broken:
another update lands in between, and yours discards it. Counting is only the
smallest example — the same goes for appending to a frozen array, merging into a
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
lv.update { it + 1 }

lv.update { it.merge(key => 1).freeze }
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
and its neighbour — not optimistic versus pessimistic, which is only how each one
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
for one variable there is nothing to express beyond a read-modify-write — which
is why reading and updating are all there is to it.

The row that decides most cases is the rollback. A `TVar` transaction that loses
a race is discarded and run again, so its block has to be safe to run twice:
anything it did that was not a `TVar` write has already happened and will happen
again. A `LockVar` update waits for its turn instead, and then runs once.

```ruby
lv.update {|v| log << v; f(v) }   # logs exactly once
```

Touching another LockVar from inside an update is refused:

```ruby
a.update {|v| b.value }
# => Ractor::LockVar::NestedLockError:
#    already updating another Ractor::LockVar;
#    use Ractor::TVar to update several variables together
```

Lock ordering is where locking goes wrong, and refusing the first nesting turns a
rare production deadlock into a deterministic error. Reaching for a second
variable is the sign that you wanted a transaction: `Ractor::TVar` logs reads and
writes and retries on conflict, so it needs no lock order at all.

No LockVar can be touched from inside an update, its own included — the block is
handed the value it needs, and a nested update's write would be discarded by the
outer block's result anyway. The holder is tracked per **thread**.

## Keep the block short

The block holds the lock while it runs, so everything else waiting on this
variable waits for it. Compute the new value and nothing more: no IO, no waiting
on anything, no calling out to code that might. This is not a `LockVar`
restriction so much as the rule for any critical section, and `TVar` wants the
same thing for its own reason — a transaction is validated against the version it
read when it started, so a long block is a long window for somebody else to
invalidate it.

## Performance

Numbers are **ns per completed operation across all Ractors**, so one that halves
when the Ractors double means it scaled. Measured on 16 cores; sources and
conditions in `~/ruby/src/trials/ractor-lockvar-vs-tvar/`.

### Independent variables — every Ractor has one of its own

```ruby
vars = n.times.map { Ractor::LockVar.new(0) }
n.times.map {|i| Ractor.new(vars[i]) {|v| K.times { v.value } } }.each(&:join)
n.times.map {|i| Ractor.new(vars[i]) {|v| K.times { v.update { it + 1 } } } }.each(&:join)
```

| Ractors | `LockVar#value` (ns/op) | `TVar#value` (ns/op) | `LockVar#update` (ns/op) | `TVar` `atomically` (ns/op) |
|---:|---:|---:|---:|---:|
| 1 | 89 | 40 | 133 | 135 |
| 2 | 45 | 20 | 66 | 84 |
| 4 | 23 | 10 | 34 | 86 |
| 8 | 13 | 7 | 25 | 86 |
| 16 | 9 | 4 | 15 | 100 |

Sixteen Ractors on sixteen LockVars complete 8.9× as many updates per second as
one Ractor does; this machine tops out around 8× on plainly parallel work, so
that is as far as anything scales here. Sixteen Ractors on sixteen *TVars* manage
1.4×. The blocks do run in parallel — it is the commit that does not: every
committing update takes one process-wide lock to allocate the next version
number, whichever variable it touched, and past two Ractors that lock is the
ceiling.

A single uncontended read costs more on a LockVar (89 ns against 40) because it
takes the lock, which is what buys the guarantee in *Reads and updates* above.
`TVar#value` outside a transaction takes nothing and guarantees nothing.

### One shared variable — every Ractor increments the same one

```ruby
v = Ractor::LockVar.new(0)
n.times.map { Ractor.new(v) {|x| K.times { x.update { it + 1 } } } }.each(&:join)
```

| Ractors | `LockVar#update` (ns/op) | `TVar` `atomically` (ns/op) |
|---:|---:|---:|
| 1 | 120 | 135 |
| 2 | 349 | 157 |
| 4 | 435 | 211 |
| 8 | 481 | 266 |
| 16 | 460 | 417 |

Neither scales — one variable is one variable — and `TVar` is ahead throughout:
the loser of a race retries a short block, where `LockVar` parks the thread and
wakes it through a port, which costs more than the block did. The gap narrows as
Ractors are added, because `TVar` spends more of its time on work it discards: at
four Ractors it runs the block 1.17× per completed update and at sixteen 1.76×,
against 1.00× by construction here.

**Do not choose `LockVar` for speed on a contended variable.** How much any of
this matters depends on how often your variable is actually contended, which is a
property of your program rather than of either class — so measure yours. What
`LockVar` gives you regardless is the row above: the block runs once.

## Implementation notes

* The lock state is protected by a native mutex that is held for a few
  instructions only and **never across Ruby code**, so a waiter can never keep
  another Ractor from reaching a GC safepoint.
* A thread that has to wait parks on a `Ractor::Port` of its own rather than on a
  condition variable. `Port#receive` goes through the VM scheduler, so the wait
  **rides the M:N scheduler** (enabled by default on non-main Ractors) and stays
  interruptible: `Thread#kill` on a waiter works and leaves the lock untouched.
* An uncontended `update` touches the native mutex only — no Port is created and
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
