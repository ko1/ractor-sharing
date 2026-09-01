# ractor-sharing

Ways for Ractors to share mutable state.

Ractors keep their objects to themselves. What crosses between them is either
frozen or copied, so there is nowhere to put a counter, a registry or a cache
that several Ractors both read and change. Each class here is such a place.

What picks one is the state you have:

| | holds | you write |
|---|---|---|
| [`Ractor::LockVar`](docs/lockvar.md) | one shareable value | `lv.update {\|v\| v + 1 }` |
| [`Ractor::TVar`](docs/tvar.md) | several shareable values, changed together | `Ractor.atomically { a.value += 1; b.value -= 1 }` |
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

**Several variables that must agree — `TVar`.** Moving a balance from one
account to another: either both variables change or neither does. A transaction
that loses a race is rolled back and run again, so its block must be safe to run
twice.

```ruby
from, to = Ractor::TVar.new(100), Ractor::TVar.new(0)
Ractor.atomically { from.value -= 10; to.value += 10 }
```

**A mutable object — `ActiveObject`.** When freezing the state is not on the
table, give the object a Ractor of its own. It never leaves; callers send method
calls in, the owner runs them one at a time, and the object goes on being an
ordinary mutable Ruby object.

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
