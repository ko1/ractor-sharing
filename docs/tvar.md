# Ractor::TVar

Several variables that change together.
[Software transactional memory](https://en.wikipedia.org/wiki/Software_transactional_memory)
for Ractors and Threads: read and write any number of TVars inside
`Ractor.atomically`, and the whole set either takes effect or does not.

```ruby
require "ractor/tvar"

from = Ractor::TVar.new(100)
to   = Ractor::TVar.new(0)

Ractor.atomically do
  from.value -= 10
  to.value   += 10        # no one ever sees the money in neither account
end
```

Nothing is locked while the block runs. Each transaction reads a consistent
snapshot and, at the end, commits only if nothing it read has changed since;
otherwise it is **rolled back and run again**. So a block may run more than once,
and must be safe to: keep it to reading and writing TVars, with no side effects
and no waiting.

```ruby
tv = Ractor::TVar.new(0)
rs = 4.times.map { Ractor.new(tv) {|t| 10_000.times { Ractor.atomically { t.value += 1 } } } }
rs.each(&:join)
tv.value #=> 40000
```

## API

```ruby
tv = Ractor::TVar.new(initial = nil)

tv.value             # read
tv.value = v         # write
tv.increment(n = 1)  # add, in one step

Ractor.atomically { ... }   # everything inside is one transaction
```

Values must be shareable; `ArgumentError` otherwise.

Outside `Ractor.atomically`, `value` and `value=` act on the variable directly
without a transaction — one read or one write, with nothing tying it to any
other. Use a transaction whenever two operations have to belong together.

`Ractor::TransactionError` is raised for a transaction that cannot proceed;
`Ractor::RetryTransaction` is what a rollback is made of.

## When something else fits better

* One variable, or a block that must not run twice —
  [`Ractor::LockVar`](lockvar.md), which waits its turn instead of retrying.
* State you do not want to freeze — a mutable object, updated in place —
  [`Ractor::ActiveObject`](active_object.md).

## Scaling

Every committing transaction takes one process-wide lock to allocate its version
number, whichever variables it touched, so commits do not run in parallel: on
sixteen Ractors updating sixteen *unrelated* TVars, throughput is about 1.4× that
of one Ractor. Transaction bodies do run in parallel; it is the commit that does
not.

Part of [ractor-sharing](../README.md).
