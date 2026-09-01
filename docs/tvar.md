# Ractor::TVar

A variable Ractors can share, and the one to reach for first.
[Software transactional memory](https://en.wikipedia.org/wiki/Software_transactional_memory)
for Ractors and Threads: read and write as many TVars as you like inside
`Ractor.atomically`, and everything that block changes takes effect together or
not at all.

A TVar holds any shareable object, not only a number:

```ruby
require "ractor/tvar"

config  = Ractor::TVar.new({ mode: :idle }.freeze)
version = Ractor::TVar.new("v1".freeze)

Ractor.atomically do
  config.value  = config.value.merge(mode: :running).freeze
  version.value = "v2".freeze             # nobody sees v1 running, or v2 idle
end
```

One variable is a transaction with one variable in it, and reads the same way:

```ruby
seen = Ractor::TVar.new([].freeze)
Ractor.atomically { seen.value = (seen.value + [:x]).freeze }
```

Where two variables have to agree, that is the whole point:

```ruby
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
tv = Ractor::TVar.new(initial = nil)   # any shareable object

Ractor.atomically { ... }   # everything inside is one transaction

tv.value             # read; inside a transaction or out
tv.value = v         # write; only inside a transaction
tv.increment(n = 1)  # add in one step; inside or out, for values that answer to +
```

Values must be shareable; `ArgumentError` otherwise.

**A write needs a transaction.** `tv.value = v` on its own raises
`Ractor::TransactionError`, "can not set without transaction". There is no
one-off write, because a write on its own is where a lost update comes from:

```ruby
Ractor.atomically { tv.value = tv.value + 1 }   # right
tv.increment                                    # right, and shorter
```

A read outside a transaction is allowed, and returns the value as it stands.
`increment` is allowed too: outside a transaction it takes the variable's own
lock and does the whole add in one step.

`Ractor::TransactionError` is raised for a transaction that cannot proceed;
`Ractor::RetryTransaction` is what a rollback is made of.

## When something else fits better

* One variable, or a block that must not run twice:
  [`Ractor::LockVar`](lockvar.md), which waits its turn instead of retrying.
* State you do not want to freeze, a mutable object updated in place:
  [`Ractor::ActorHash`](actor_hash.md) or [`Ractor::ActiveObject`](active_object.md).

## Scaling

Every committing transaction takes one process-wide lock to allocate its version
number, whichever variables it touched, so commits do not run in parallel: on
sixteen Ractors updating sixteen *unrelated* TVars, throughput is about 1.4× that
of one Ractor. Transaction bodies do run in parallel; it is the commit that does
not.

Part of [ractor-sharing](../README.md).
