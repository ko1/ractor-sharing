# frozen_string_literal: true

require_relative "test_helper"

class LockVarTest < Test::Unit::TestCase
  HELD = 0.15 # how long a holder keeps the lock when a test needs it held

  # "Is it still held" can only be observed by trying to take it, which is also
  # the property we actually care about.
  def assert_acquirable(lv, timeout: 3, message: "LockVar is still held")
    q = Queue.new
    t = Thread.new { lv.update { |v| q << :got; v } }
    assert_not_nil q.pop(timeout: timeout), message
    t.join(timeout)
  end

  def assert_not_acquirable(lv, wait: 0.1)
    q = Queue.new
    t = Thread.new { lv.update { |v| q << :got; v } }
    assert_nil q.pop(timeout: wait), "LockVar should still be held"
    t.kill
    t.join(3)
  end

  # Runs a thread that holds the lock until it is killed; returns it.
  def hold(lv, secs = 5)
    q = Queue.new
    t = Thread.new { lv.update { |v| q << :held; sleep secs; v } }
    q.pop
    t
  end

  # --- API ---------------------------------------------------------------

  def test_public_api
    assert_equal %i[increment inspect update value],
                 Ractor::LockVar.instance_methods(false).sort
  end

  def test_value
    assert_equal 1, Ractor::LockVar.new(1).value
    assert_nil Ractor::LockVar.new.value
  end

  def test_only_shareable_values
    assert_raise(ArgumentError) { Ractor::LockVar.new({}) }
    lv = Ractor::LockVar.new(1)
    assert_raise(ArgumentError) { lv.update { [] } }
    assert_equal 1, lv.value, "a rejected update leaves the value alone"
    assert_acquirable lv
    lv.update { [1, 2].freeze }
    assert_equal [1, 2], lv.value
  end

  def test_lockvar_is_frozen_and_shareable
    lv = Ractor::LockVar.new(1)
    assert_true Ractor.shareable?(lv)
    assert_true lv.frozen?
    assert_equal 1, Ractor.new(lv) { |v| v.value }.value
  end

  def test_inspect_does_not_take_the_lock
    lv = Ractor::LockVar.new(42)
    assert_equal "#<Ractor::LockVar 42>", lv.inspect
    t = hold(lv)
    assert_equal "#<Ractor::LockVar 42>", lv.inspect, "inspect must never block"
    t.kill
    t.join(3)
  end

  # --- update -------------------------------------------------------------

  def test_update_returns_the_new_value_and_yields_the_old
    lv = Ractor::LockVar.new(:old)
    seen = nil
    assert_equal :new, lv.update { |v| seen = v; :new }
    assert_equal :old, seen
    assert_equal :new, lv.value
  end

  def test_update_without_block
    assert_raise(LocalJumpError) { Ractor::LockVar.new.update }
  end

  def test_update_exception_leaves_the_value_and_releases
    lv = Ractor::LockVar.new(1)
    assert_raise(RuntimeError) { lv.update { raise "boom" } }
    assert_equal 1, lv.value
    assert_acquirable lv
  end

  def test_non_local_exits_release_the_lock
    lv = Ractor::LockVar.new(0)
    assert_equal :returned, ->{ lv.update { return :returned }; :no }.call
    assert_acquirable lv, message: "return must release the lock"

    assert_equal :broke, lv.update { break :broke }
    assert_acquirable lv, message: "break must release the lock"

    assert_equal :thrown, catch(:tag) { lv.update { throw :tag, :thrown } }
    assert_acquirable lv, message: "throw must release the lock"

    assert_equal 0, lv.value, "none of those wrote a value"
  end

  def test_update_is_atomic_across_threads
    lv = Ractor::LockVar.new(0)
    threads = 8.times.map { Thread.new { 200.times { lv.update { |n| n + 1 } } } }
    threads.each(&:join)
    assert_equal 1600, lv.value
  end

  def test_update_is_atomic_across_ractors
    lv = Ractor::LockVar.new(0)
    rs = 4.times.map { Ractor.new(lv) { |v| 100.times { v.update { |n| n + 1 } }; :ok } }
    rs.each(&:join)
    assert_equal 400, lv.value
  end

  def test_critical_section_is_not_interleaved
    lv = Ractor::LockVar.new(0)
    rs = 4.times.map do
      Ractor.new(lv) { |v| 100.times { v.update { |n| Thread.pass; n + 1 } }; :ok }
    end
    rs.each(&:join)
    assert_equal 400, lv.value
  end

  # --- increment ----------------------------------------------------------

  def test_increment
    lv = Ractor::LockVar.new(0)
    assert_equal 1, lv.increment
    assert_equal 6, lv.increment(5)
    assert_equal 4, lv.increment(-2)
    assert_equal 4, lv.value
  end

  def test_increment_uses_plus
    lv = Ractor::LockVar.new(1.5)
    assert_equal 2.5, lv.increment
    lv = Ractor::LockVar.new([1].freeze)
    assert_raise(ArgumentError, "the sum of two frozen arrays is not frozen") do
      lv.increment([2].freeze)
    end
    assert_equal [1], lv.value
    assert_acquirable lv
  end

  def test_increment_on_a_value_without_plus
    lv = Ractor::LockVar.new(:sym)
    assert_raise(NoMethodError) { lv.increment }
    assert_equal :sym, lv.value
    assert_acquirable lv
  end

  def test_increment_is_atomic_across_ractors
    lv = Ractor::LockVar.new(0)
    rs = 4.times.map { Ractor.new(lv) { |v| 300.times { v.increment }; :ok } }
    rs.each(&:join)
    assert_equal 1200, lv.value
  end

  def test_increment_inside_an_update_is_refused
    lv = Ractor::LockVar.new(0)
    assert_raise(Ractor::LockVar::NestedLockError) { lv.update { |v| lv.increment } }
    assert_equal 0, lv.value
    assert_acquirable lv
  end

  # --- reads --------------------------------------------------------------

  def test_value_inside_its_own_update_is_refused
    lv = Ractor::LockVar.new(7)
    e = assert_raise(Ractor::LockVar::NestedLockError) { lv.update { |v| lv.value } }
    assert_match(/given that value already/, e.message)
    assert_acquirable lv
  end

  def test_value_waits_for_an_update_in_flight
    lv = Ractor::LockVar.new(0)
    q = Queue.new
    t = Thread.new { lv.update { |v| q << :held; sleep HELD; 1 } }
    q.pop
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal 1, lv.value, "a reader must see the finished update"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :>, HELD / 2
    t.join(3)
  end

  # Why #value takes the lock: an update block is atomic for readers, not just
  # its final store. lv.update {|v| last = v; v + 1 } must leave every reader
  # seeing lv.value > last.
  def test_update_block_is_atomic_for_readers
    lv = Ractor::LockVar.new(0)
    last = [-1] # plain shared state, written from inside the update block
    stop = false
    violations = 0
    checks = 0
    lock = Mutex.new

    readers = 2.times.map do
      Thread.new do
        v = 0
        c = 0
        until stop
          seen = last[0]
          cur = lv.value
          c += 1
          v += 1 if cur <= seen
          Thread.pass
        end
        lock.synchronize { violations += v; checks += c }
      end
    end

    300.times do
      lv.update { |v| last[0] = v; Thread.pass; v + 1 }
      sleep 0.0002
    end
    stop = true
    readers.each { |t| t.join(10) or flunk "reader hung" }

    assert_operator checks, :>, 500, "readers barely ran; the check is meaningless"
    assert_equal 0, violations, "#{violations}/#{checks} reads saw lv.value <= last"
  end

  # --- nesting ------------------------------------------------------------

  def test_reentrant_update_is_refused
    lv = Ractor::LockVar.new(0)
    e = assert_raise(Ractor::LockVar::NestedLockError) { lv.update { lv.update { 9 } } }
    assert_match(/discarded by the outer block/, e.message)
    assert_equal 0, lv.value
    assert_acquirable lv
  end

  def test_touching_a_different_lockvar_while_updating_raises
    a = Ractor::LockVar.new(0)
    b = Ractor::LockVar.new(9)
    e = assert_raise(Ractor::LockVar::NestedLockError) { a.update { |v| b.update { 1 }; v } }
    assert_match(/TVar/, e.message)
    assert_raise(Ractor::LockVar::NestedLockError) { a.update { |v| b.value } }
    assert_acquirable a
    assert_acquirable b
  end

  def test_nesting_error_is_a_thread_error
    assert_operator Ractor::LockVar::NestedLockError, :<, ThreadError
  end

  def test_no_lockvar_can_be_touched_inside_an_update
    lv = Ractor::LockVar.new(0)
    other = Ractor::LockVar.new(1)
    [->{ lv.value }, ->{ lv.update { 9 } },
     ->{ other.value }, ->{ other.update { 9 } }].each do |op|
      assert_raise(Ractor::LockVar::NestedLockError) { lv.update { |v| op.call } }
    end
    assert_equal 0, lv.value
    assert_equal 1, other.value
    assert_acquirable lv
  end

  def test_different_var_after_release_is_fine
    a = Ractor::LockVar.new(0)
    b = Ractor::LockVar.new(0)
    a.update { |v| v }
    assert_equal 1, b.update { 1 }
    a.update { |v| v }
  end

  def test_held_state_is_per_thread
    a = Ractor::LockVar.new(0)
    b = Ractor::LockVar.new(0)
    a.update { |v| assert_equal 1, Thread.new { b.update { 1 } }.value; v }
  end

  # --- Thread#kill / Thread#raise -----------------------------------------

  def test_killing_the_holder_releases_the_lock
    lv = Ractor::LockVar.new(0)
    t = hold(lv)
    t.kill
    t.join(3)
    assert_acquirable lv, message: "killing the holder must release the lock"
  end

  def test_killing_the_holder_wakes_a_waiter
    lv = Ractor::LockVar.new(0)
    got = Queue.new
    holder = hold(lv)
    waiter = Thread.new { lv.update { |v| got << :acquired; v } }
    sleep 0.05
    holder.kill
    assert_not_nil got.pop(timeout: 3), "the waiter must be woken when the holder dies"
    [holder, waiter].each { |t| t.join(3) }
  end

  def test_killing_a_waiter_leaves_the_lock_alone
    lv = Ractor::LockVar.new(0)
    holder = hold(lv)
    waiters = 3.times.map { Thread.new { lv.update { |v| v } } }
    sleep 0.05
    waiters.each(&:kill)
    waiters.each { |t| t.join(3) or flunk "a blocked waiter could not be killed" }
    assert_not_acquirable lv
    holder.kill
    holder.join(3)
    assert_acquirable lv
  end

  def test_killing_some_of_many_waiters_still_lets_the_rest_through
    lv = Ractor::LockVar.new(0)
    done = Queue.new
    holder = hold(lv, HELD)
    waiters = 5.times.map { |i| Thread.new { lv.update { |v| done << i; v } } }
    sleep 0.05
    waiters[0].kill
    waiters[2].kill
    3.times { assert_not_nil done.pop(timeout: 5), "surviving waiters must all acquire" }
    ([holder] + waiters).each { |t| t.join(5) }
    assert_acquirable lv
  end

  def test_exception_raised_while_waiting
    lv = Ractor::LockVar.new(0)
    holder = hold(lv)
    waiter = Thread.new { lv.update { |v| v } }
    sleep 0.05
    waiter.raise(ArgumentError, "stop waiting")
    assert_raise(ArgumentError) { waiter.value }
    holder.kill
    holder.join(3)
    assert_acquirable lv
  end

  def test_kill_at_a_random_moment_never_strands_the_lock
    40.times do |i|
      lv = Ractor::LockVar.new(0)
      t = Thread.new { loop { lv.update { |n| n + 1 } } }
      sleep(rand * 0.001)
      t.kill
      t.join(3) or flunk "thread did not die (iteration #{i})"
      assert_acquirable lv, message: "lock stranded at iteration #{i}"
    end
  end

  def test_kill_a_contended_lock_repeatedly
    10.times do |i|
      lv = Ractor::LockVar.new(0)
      ts = 4.times.map { Thread.new { loop { lv.update { |n| n + 1 } } } }
      sleep(rand * 0.005)
      ts.each(&:kill)
      ts.each { |t| t.join(3) or flunk "thread did not die (iteration #{i})" }
      assert_acquirable lv, message: "lock stranded at iteration #{i}"
    end
  end

  # --- concurrency / resources --------------------------------------------

  def test_many_waiters_all_get_through
    lv = Ractor::LockVar.new(0)
    n = 12
    threads = n.times.map { Thread.new { lv.update { |v| Thread.pass; v + 1 } } }
    threads.each { |t| t.join(10) or flunk "a waiter never acquired the lock" }
    assert_equal n, lv.value
  end

  def test_uncontended_update_creates_no_port
    lv = Ractor::LockVar.new(0)
    GC.start
    before = ObjectSpace.each_object(Ractor::Port).count
    500.times { lv.update { |v| v } }
    assert_equal before, ObjectSpace.each_object(Ractor::Port).count
  end

  def test_gc_while_waiters_are_parked
    lv = Ractor::LockVar.new(0)
    holder = hold(lv, HELD)
    waiters = 5.times.map { Thread.new { lv.update { |n| n + 1 } } }
    sleep 0.05
    3.times { GC.start }
    waiters.each { |t| t.join(10) or flunk "a waiter was lost across GC" }
    holder.join(5)
    assert_equal 5, lv.value
  end

  def test_ractor_dying_while_holding_releases_the_lock
    lv = Ractor::LockVar.new(0)
    port = Ractor::Port.new
    Ractor.new(lv, port) { |v, p| v.update { |x| p << :held; raise "die inside" } }
    port.receive
    assert_acquirable lv, timeout: 5,
                      message: "a Ractor dying inside update must release the lock"
  end
end
