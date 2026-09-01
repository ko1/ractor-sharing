# Ractor::ActiveObject

`Ractor::ActiveObject` runs the [Active Object pattern](https://en.wikipedia.org/wiki/Active_object)
on Ractors: each instance's state is owned by a dedicated *owner Ractor*, and
method calls from any other Ractor are forwarded to it and executed there one
at a time. The model is "move the request to the data owner", not "move the
data to the computation".

From the user's point of view it is an ordinary Ruby class whose public
interface is *published* with `sync` / `async` / `future`.

```ruby
require "ractor/active_object"

class People < Ractor::ActiveObject
  def initialize
    @db = {}
  end

  async def add(name, age)   # fire-and-forget
    @db[name] = age
  end

  sync def find(name)        # wait for the result
    @db[name]
  end

  future def load_all         # returns a Future immediately
    @db.dup
  end
end

PEOPLE = People.new          # proxy is shareable: usable from any Ractor
PEOPLE.add("ko1", 46)

Ractor.new do
  p PEOPLE.find("ko1")       # => 46
  f = PEOPLE.load_all
  p f.value                  # => {"ko1" => 46}
end.join
```

Requires Ruby 4.0 or later (`Ractor::Port`).

## What it costs

Each instance starts a Ractor of its own, and that Ractor runs until the process
ends: there is no shutdown. Creating active objects in a loop leaks them.

Every `sync` call from another Ractor is a message round trip, about **2.6 µs**
measured on 16 cores, where the same update on an uncontended
`Ractor::LockVar` is **0.35 µs**. From the main Ractor rather than a worker it is
**8.9 µs**, because that thread has a native thread to itself and waking it is a
syscall. Calls to one object run one at a time on its owner, so a single hot
object caps how fast callers get through it.

**An `async` method is the one to reach for when nothing needs the answer**, since
the round trip is most of the cost: sixteen Ractors with an object each get
through `async` calls at **0.18 µs**, against 0.76 µs for the same method declared
`sync`. Reads have to be `sync`, because the answer is the point.

None of that applies to calls made *inside* the owner: those are plain Ruby
calls. And if the state you are guarding fits in a shareable value,
[`Ractor::LockVar`](lockvar.md) or [`Ractor::TVar`](tvar.md) will be much
cheaper.

## Invocation policies

| modifier | explicit form          | caller waits? | returns              | exception                     |
|----------|------------------------|---------------|----------------------|-------------------------------|
| `sync`   | `obj.sync_send(m, …)`  | yes           | the method's result  | re-raised in the caller       |
| `async`  | `obj.async_send(m, …)` | no            | `nil`                | `#on_async_exception` (owner) |
| `future` | `obj.future_send(m, …)`| no            | `Future`             | raised by `Future#value`      |

* `sync`, `async` and `future` are class-level DSL methods that take method
  names, so they compose like `private`: `async def foo…`, `async :foo, :bar`,
  `sync attr_reader :size`. Declaring a method *publishes* it on the proxy,
  regardless of its visibility in the class.
* **`Foo.new` returns a proxy (an instance of `Foo::Proxy`), not a `Foo`.**
  The proxy has exactly the published methods plus `sync_send` / `async_send`
  / `future_send`, `owner`, `owner?`, `active_object_class`. Undeclared methods
  raise `NoMethodError` on the proxy; `*_send` can still reach them, like
  `__send__`.
* `*_send` always overrides the declared policy.
* `Klass.invocation_policy(:name)` returns `:sync` / `:async` / `:future`
  (or `nil` if not published); `Klass.proxy_class` is the proxy class.

### Calls on the owner Ractor

Inside the owner Ractor the object is a plain `Foo` instance (the *servant*):
calls between its methods are ordinary Ruby calls, with no mailbox and no policy;
`async` methods run immediately and return their real value. A proxy used
inside its own owner Ractor (e.g. through a constant) also calls the servant
directly. `owner?` tells you which side you are on; `owner` is the owner
Ractor. A method that returns `self` hands the caller the proxy.

### Ordering

Requests from one thread are executed in the order they were sent, one at a
time per object. A `sync` call therefore works as a barrier after `async`
calls:

```ruby
class Cache < Ractor::ActiveObject
  def initialize = @c = {}
  async def set(k, v) = @c[k] = v
  sync  def nop = nil
end
cache = Cache.new

cache.set(:x, 1)        # async
cache.sync_send(:nop)   # everything above has been applied
```

### Arguments and results

Arguments and results cross Ractors with the normal `Ractor#send` semantics
(copy, or share by reference if shareable). Values that cannot be sent raise
`TypeError` at the caller (arguments) or come back as
`Ractor::ActiveObject::Error` (results / exceptions), so a caller never hangs.
Exceptions keep the owner-side backtrace, followed by the caller's frames.

Blocks cannot be passed to remote invocations (`ArgumentError`); they work for
calls made on the owner Ractor.

`sync` calls take their reply port from a Ractor-local pool
(`Ractor[:__ao_reply_ports__]`, an Array), so steady-state calls allocate no
port. A port is owned exclusively by one caller while in use, so concurrent
threads of a Ractor never see each other's replies; the pool grows to the
number of concurrent callers. A port whose wait was interrupted (e.g. by
`Timeout`) is discarded, never reused. `future` calls always get a fresh port.

A caller waits on its reply port alone (`Port#receive`), not on
`Ractor.select(reply, owner)`: watching the owner as well costs ≈4 % of a
2 µs `sync` call. The owner is not expected to die, since its request loop
rescues `Exception`, and if it does go down with a request in flight it
answers that caller with an `ActiveObject::Error` from an `ensure`, while any
later send fails fast with `Ractor::ClosedError` → `ActiveObject::Error`.

The gap this leaves is a caller whose request was still queued when the owner
died: it stays blocked in `receive`. Waking it would need either the
per-call `Ractor.select`, or `Ractor#monitor` on the reply port, but
`monitor` delivers a bare `:exited` that does not say which Ractor exited, so
reply ports would have to be pooled per owner, and that bookkeeping costs the
same ≈4 %. (`Port#close` is not an option: it cannot be called from another
Ractor, and even from the owning Ractor it does not wake a thread already
blocked in `receive`.) Both were measured and rejected.

### Futures

```ruby
class Slow < Ractor::ActiveObject
  future def compute(x) = x * 2
end
obj = Slow.new

f = obj.future_send(:compute, 1)
f.value       # waits; returns the result or raises the method's exception
f.wait        # waits; returns self, never raises
f.resolved?   # true once the result has been observed by #value / #wait
f.rejected?
```

A `Future` can be consumed only in the Ractor that created it (its reply port
belongs to that Ractor). Threads inside that Ractor may share it.

### Async errors

An exception raised by an `async` invocation is passed to
`on_async_exception(exception, method_name)` on the owner. The default
implementation prints a warning; override it to supervise:

```ruby
class Worker < Ractor::ActiveObject
  def initialize = @failures = []
  sync def failures = @failures.map(&:first)

  def on_async_exception(e, name)
    @failures << [name, e]
  end
end
```

### Lifecycle

`Klass.new(*args, **kwargs)` starts the owner Ractor, runs `initialize` there
(exceptions propagate to the caller) and returns a frozen, shareable proxy.
The owner Ractor serves requests until the process exits. If it terminates
for another reason, the in-flight call and every later call raise
`Ractor::ActiveObject::Error`; requests already queued behind it, whose
callers are blocked on their reply ports, are the one case that can hang.

## Implementation notes and limitations

* `Foo::Proxy` is created when `Foo` is defined (`Foo < Bar` gives
  `Foo::Proxy < Bar::Proxy`, so published methods are inherited). Declaring a
  method defines a forwarding method on the proxy class. A subclass that
  overrides a published method keeps the parent's policy unless it declares
  the method again.
* The servant is untouched: no wrappers, `super` and private calls work as in
  any Ruby class.
* Subclasses must be defined in the main Ractor (class definition needs to
  store class-level state, which non-main Ractors cannot do).
* `proxy.is_a?(Foo)` is false; use `proxy.active_object_class` or
  `Foo.proxy_class === proxy`.
* `Future#ready?` (non-blocking check) is not provided: `Ractor::Port` has no
  non-blocking receive.
* Ruby prints "Ractor API is experimental" on the first `Ractor.new`; silence
  it with `Warning[:experimental] = false` if you want.

Part of [ractor-sharing](../README.md).
