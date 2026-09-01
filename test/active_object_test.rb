# frozen_string_literal: true

require_relative "test_helper"

class TestActiveObject < Test::Unit::TestCase
  test "there is one proxy per object, and returning self hands it back" do
    k = Class.new(Ractor::ActiveObject) do
      sync def bump = self
    end
    p1 = k.new
    assert_true p1.equal?(p1.bump), "the same proxy object, not a second one"
    assert_true Ractor.new(p1) { |x| x.bump.equal?(x) }.value, "from another Ractor too"
  end

  test "a frozen shareable exception from the servant arrives unmasked" do
    k = Class.new(Ractor::ActiveObject) do
      sync def boom = raise(Ractor.make_shareable(RuntimeError.new("frozen boom")))
    end
    obj = k.new
    e = Ractor.new(obj) { |o| begin; o.boom; :no_raise; rescue => x; [x.class.to_s, x.message]; end }.value
    assert_equal ["RuntimeError", "frozen boom"], e,
                 "set_backtrace on the frozen exception used to mask it with FrozenError"
  end

  include RactorHelper

  class Cache < Ractor::ActiveObject
    sync attr_reader :hits

    def initialize(initial = {}, prefix: "")
      @cache = initial.dup
      @prefix = prefix
      @hits = 0
    end

    async def set(key, value)
      @cache[key] = value
    end

    sync def get(key)
      @hits += 1
      @cache[key]
    end

    future def slow_get(key, delay: 0.01)
      sleep delay
      @cache[key]
    end

    def plain = :plain

    sync def prefixed(key) = "#{@prefix}#{@cache[key]}"

    sync def nop = nil

    sync def boom(msg = "boom") = raise(ArgumentError, msg)

    sync def owner_side_calls
      set(:from_owner, 1)              # direct call, must not enqueue
      [get(:from_owner), owner?, sync_send(:get, :from_owner), async_send(:nop), future_send(:get, :from_owner).value]
    end

    sync def me = self

    sync def unsendable = proc {}

    sync def raise_unsendable
      e = RuntimeError.new("has a proc")
      e.instance_variable_set(:@blk, proc {})
      raise e
    end

    sync def with_block = yield

    sync def call_private = secret

    private

    def secret = :secret
  end

  def test_basic_sync_async_from_other_ractor
    cache = Cache.new
    assert_nil cache.set(:a, 1)
    assert_equal 1, cache.get(:a)
    assert_equal 1, in_ractor(cache) { |c| c.get(:a) }
    assert_equal 2, cache.hits
  end

  def test_undeclared_methods_are_not_published
    cache = Cache.new
    assert_nil Cache.invocation_policy(:plain)
    assert_raise(NoMethodError) { cache.plain }
    assert_false cache.respond_to?(:plain)
    assert_true cache.respond_to?(:get)
    assert_equal :plain, cache.sync_send(:plain)     # explicit send still reaches the owner
  end

  def test_proxy_class
    cache = Cache.new
    assert_kind_of Ractor::ActiveObject::Proxy, cache
    assert_same Cache.proxy_class, cache.class
    assert_same Cache, cache.active_object_class
    assert_equal "TestActiveObject::Cache::Proxy", cache.class.name
    sub = Class.new(Cache)
    assert_true sub.proxy_class < Cache.proxy_class
  end

  def test_initialize_args_and_kwargs
    cache = Cache.new({ x: 10 }, prefix: "p-")
    assert_equal "p-10", cache.prefixed(:x)
  end

  def test_initialize_exception_propagates
    klass = Class.new(Ractor::ActiveObject) { def initialize = raise(IOError, "init failed") }
    e = assert_raise(IOError) { klass.new }
    assert_equal "init failed", e.message
  end

  def test_proxy_is_shareable
    cache = Cache.new
    assert_true Ractor.shareable?(cache)
    assert_true cache.frozen?
  end

  def test_future
    cache = Cache.new
    cache.set(:k, :v)
    f = cache.slow_get(:k)
    assert_kind_of Ractor::ActiveObject::Future, f
    assert_false f.resolved?
    assert_equal :v, f.value
    assert_true f.resolved?
    assert_equal :v, f.value # cached
  end

  def test_future_rejected
    cache = Cache.new
    f = cache.future_send(:boom, "bad")
    assert_same f, f.wait
    assert_true f.rejected?
    e = assert_raise(ArgumentError) { f.value }
    assert_equal "bad", e.message
  end

  def test_sync_exception_propagates_with_backtrace
    cache = Cache.new
    e = assert_raise(ArgumentError) { cache.boom("from owner") }
    assert_equal "from owner", e.message
    assert(e.backtrace.any? { |l| l.include?("boom") }, "owner frames kept: #{e.backtrace.inspect}")
    assert(e.backtrace.any? { |l| l.include?(__FILE__) && l.include?("test_sync_exception_propagates") },
           "caller frames appended: #{e.backtrace.inspect}")
  end

  def test_explicit_send_overrides_policy
    cache = Cache.new
    assert_equal 1, cache.sync_send(:set, :x, 1)          # async method, waited
    assert_nil cache.async_send(:get, :x)                 # sync method, fire-and-forget
    assert_equal 1, cache.future_send(:get, :x).value     # sync method, as future
    assert_equal :secret, cache.sync_send(:secret)        # like __send__, private is callable
  end

  def test_async_then_sync_barrier_ordering
    cache = Cache.new
    100.times { |i| cache.set(:n, i) }
    assert_equal 99, cache.get(:n)
    cache.async_send(:set, :n, :last)
    cache.sync_send(:nop)
    assert_equal :last, cache.get(:n)
  end

  def test_owner_side_direct_calls
    cache = Cache.new
    assert_equal [1, true, 1, nil, 1], cache.owner_side_calls
  end

  def test_owner_introspection
    cache = Cache.new
    assert_kind_of Ractor, cache.owner
    assert_not_same Ractor.current, cache.owner
    assert_false cache.owner?
    assert_match(/#<TestActiveObject::Cache::Proxy owner=#<Ractor:/, cache.inspect)
  end

  def test_invocation_policy
    assert_equal :async, Cache.invocation_policy(:set)
    assert_equal :sync, Cache.invocation_policy(:get)
    assert_equal :future, Cache.invocation_policy(:slow_get)
    assert_equal :sync, Cache.invocation_policy(:hits) # sync attr_reader
    assert_nil Cache.invocation_policy(:no_such_method)
  end

  def test_redeclaring_policy_replaces_wrapper
    klass = Class.new(Ractor::ActiveObject) do
      def initialize = (@v = 0)
      async def bump = (@v += 1)
      sync def v = @v
    end
    obj = klass.new
    assert_nil obj.bump
    klass.instance_eval { sync :bump }
    assert_equal 2, obj.bump
    assert_equal :sync, klass.invocation_policy(:bump)
  end

  def test_policy_dsl_returns_name_and_validates
    assert_equal :get, Cache.instance_eval { sync :get }
    assert_raise(NameError) { Cache.instance_eval { async :no_such_method } }
    assert_raise(ArgumentError) { Cache.instance_eval { async } }
    assert_raise(TypeError) { Ractor::ActiveObject.instance_eval { sync :inspect } }
    assert_equal :sync, Cache.invocation_policy(:get)
  end

  def test_private_method_is_not_callable_via_proxy
    cache = Cache.new
    assert_raise(NoMethodError) { cache.secret }
    assert_raise(NoMethodError) { in_ractor(cache) { |c| c.secret } }
    assert_equal :secret, cache.call_private
  end

  def test_declaring_a_private_method_publishes_it
    klass = Class.new(Ractor::ActiveObject) do
      private def hidden = :hidden
      sync :hidden
      def secret = :secret
      private :secret
    end
    obj = klass.new
    assert_equal :hidden, obj.hidden
    assert_raise(NoMethodError) { obj.secret }
    assert_equal :secret, obj.sync_send(:secret)
  end

  def test_inheritance
    base = Class.new(Ractor::ActiveObject) do
      def initialize = (@log = [])
      async def foo = @log << :base_foo
      async def bar = @log << :base_bar
      sync def log = @log
    end
    sub = Class.new(base) do
      sync def foo = (@log << :sub_foo; super; @log.size)
      sync def bar = (@log << :sub_bar; @log.size)
    end
    assert_equal :async, base.invocation_policy(:foo)
    assert_equal :sync, sub.invocation_policy(:foo)
    assert_equal :sync, sub.invocation_policy(:bar)
    assert_equal :async, base.invocation_policy(:bar)

    obj = sub.new
    assert_equal 2, obj.foo
    assert_equal 3, obj.bar
    assert_equal %i[sub_foo base_foo sub_bar], obj.log
  end

  def test_inherited_declaration_without_override
    base = Class.new(Ractor::ActiveObject) do
      def initialize = (@n = 0)
      async def incr = (@n += 1)
      sync def n = @n
    end
    sub = Class.new(base)
    obj = sub.new
    obj.incr
    assert_equal 1, obj.n
    assert_equal :async, sub.invocation_policy(:incr)
  end

  def test_included_module_methods_can_be_declared
    mod = Module.new { def bump = (@n = (@n || 0) + 1) }
    klass = Class.new(Ractor::ActiveObject) { include mod; sync :bump }
    obj = klass.new
    assert_equal 1, obj.bump
    assert_equal 2, in_ractor(obj) { |o| o.bump }
  end

  def test_block_not_supported_remotely
    cache = Cache.new
    assert_raise(ArgumentError) { cache.with_block { 1 } }
    assert_raise(ArgumentError) { cache.sync_send(:with_block) { 1 } }
    assert_raise(ArgumentError) { Cache.new { 1 } }
  end

  def test_unsendable_result_becomes_error_instead_of_hang
    cache = Cache.new
    e = assert_raise(Ractor::ActiveObject::Error) { cache.unsendable }
    assert_match(/return value could not be transferred/, e.message)
    e = assert_raise(Ractor::ActiveObject::Error) { cache.raise_unsendable }
    assert_match(/RuntimeError: has a proc/, e.message)
    assert_nil cache.nop, "owner still alive"
  end

  def test_unsendable_argument_raises_at_caller
    cache = Cache.new
    assert_raise(TypeError) { cache.set(:k, proc {}) }
  end

  def test_returning_self_yields_the_proxy
    cache = Cache.new
    cache.set(:a, 1)
    other = cache.me
    assert_kind_of Cache.proxy_class, other
    assert_same cache.owner, other.owner
    assert_equal 1, other.get(:a)
    cache.set(:a, 2)
    assert_equal 2, other.get(:a)
  end

  def test_async_exception_is_reported
    klass = Class.new(Ractor::ActiveObject) do
      def initialize = (@errors = [])
      async def fail_async = raise("async boom")
      sync def errors = @errors
      def on_async_exception(e, name) = @errors << [name, e.message]
    end
    obj = klass.new
    obj.fail_async
    assert_equal [[:fail_async, "async boom"]], obj.errors
  end

  def test_default_async_exception_handler_warns
    klass = Class.new(Ractor::ActiveObject) { async def fail_async = raise("async boom") }
    obj = klass.new
    err = $stderr.dup
    r, w = IO.pipe
    $stderr.reopen(w)
    begin
      obj.fail_async
      obj.sync_send(:itself)
    ensure
      $stderr.reopen(err)
      w.close
    end
    assert_match(/fail_async \(async\) raised RuntimeError: async boom/, r.read)
  end

  def test_owner_termination_answers_the_in_flight_call
    klass = Class.new(Ractor::ActiveObject) { sync def die = Thread.current.kill }
    obj = klass.new
    e = assert_raise(Ractor::ActiveObject::Error) { obj.die }
    assert_match(/terminated during/, e.message)
    # later calls fail fast because the dead owner's request port is closed
    e = assert_raise(Ractor::ActiveObject::Error) { obj.sync_send(:itself) }
    assert_match(/terminated/, e.message)
    assert_raise(Ractor::ActiveObject::Error) { obj.async_send(:itself) }
  end

  def test_owner_dying_during_initialize_does_not_hang
    klass = Class.new(Ractor::ActiveObject) { def initialize = Thread.current.kill }
    e = assert_raise(Ractor::ActiveObject::Error) { klass.new }
    assert_match(/terminated during initialization/, e.message)
  end

  def test_concurrent_callers_serialize_on_owner
    counter = Class.new(Ractor::ActiveObject) do
      def initialize = (@n = 0)
      async def incr = (@n += 1)
      sync def n = @n
      sync def racy_incr
        v = @n
        Thread.pass
        @n = v + 1
      end
    end.new
    ractors = 8.times.map { Ractor.new(counter) { |c| 500.times { c.incr; c.racy_incr }; :ok } }
    ractors.each(&:join)
    assert_equal 8000, counter.n
  end

  def test_reply_port_is_pooled_per_ractor
    cache = Cache.new
    cache.nop
    pool = Ractor[:__ao_reply_ports__]
    assert_kind_of Array, pool
    size = pool.size
    port = pool.last
    cache.nop
    assert_same port, pool.last, "the same port is taken and returned"
    assert_equal size, pool.size, "a sequential call does not grow the pool"
    assert_not_same port, in_ractor(cache) { |c| c.nop; Ractor[:__ao_reply_ports__].last }
  end

  def test_interrupted_sync_call_drops_the_port
    cache = Cache.new
    cache.nop
    pool = Ractor[:__ao_reply_ports__]
    size = pool.size
    port = pool.last
    t = Thread.current
    interrupter = Thread.new { sleep 0.05; t.raise(Interrupt) }
    assert_raise(Interrupt) { cache.sync_send(:sleep, 0.5) }
    interrupter.join
    assert_equal size - 1, pool.size, "abandoned port is not returned to the pool"
    assert_not_include pool, port
    # the late reply must not be picked up by the next call
    cache.set(:k, :v)
    assert_equal :v, cache.get(:k)
  end

  def test_threads_in_one_ractor
    cache = Cache.new
    threads = 4.times.map { |i| Thread.new { 100.times { |j| cache.set([i, j], j) }; cache.get([i, 99]) } }
    assert_equal [99] * 4, threads.map(&:value)
  end

  # Concurrent sync calls must never receive each other's reply, whether they
  # share a pooled port or not.
  def test_pooled_ports_do_not_mix_replies_between_threads
    echo = Class.new(Ractor::ActiveObject) { sync def echo(v) = v }.new
    results = 8.times.map do |i|
      Thread.new { 200.times.map { |j| echo.echo([i, j]) == [i, j] }.all? }
    end.map(&:value)
    assert_equal [true] * 8, results
    assert_operator Ractor[:__ao_reply_ports__].size, :<=, 8
  end

  def test_keyword_and_hash_arguments
    klass = Class.new(Ractor::ActiveObject) do
      sync def pos(h) = h
      sync def kw(a:, b: 2) = [a, b]
      sync def both(*args, **kw) = [args, kw]
    end
    obj = klass.new
    assert_equal({ a: 1 }, obj.pos({ a: 1 }))
    assert_equal([1, 2], obj.kw(a: 1))
    assert_equal([[1, { x: 1 }], { y: 2 }], obj.both(1, { x: 1 }, y: 2))
    assert_equal([[], {}], obj.both)
  end

  def test_operator_and_predicate_method_names
    klass = Class.new(Ractor::ActiveObject) do
      def initialize = (@h = {})
      async def []=(k, v)
        @h[k] = v
      end
      sync def [](k) = @h[k]
      sync def empty? = @h.empty?
      sync def +(other) = @h.size + other
    end
    obj = klass.new
    assert_true obj.empty?
    obj[:a] = 1
    assert_equal 1, obj[:a]
    assert_equal 11, obj + 10
  end

  def test_allocate_without_new_raises_clearly
    e = assert_raise(Ractor::ActiveObject::Error) { Cache.allocate.sync_send(:nop) }
    assert_match(/not created by .new/, e.message)
  end

  def test_nested_active_objects
    outer = Class.new(Ractor::ActiveObject) do
      def initialize = (@inner = TestActiveObject::Cache.new)
      sync def put(k, v) = @inner.sync_send(:set, k, v)
      sync def fetch(k) = @inner.get(k)
    end
    obj = outer.new
    obj.put(:z, 26)
    assert_equal 26, obj.fetch(:z)
  end
end
