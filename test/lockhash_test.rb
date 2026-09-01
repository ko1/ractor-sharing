# frozen_string_literal: true

require_relative "test_helper"

class LockHashTest < Test::Unit::TestCase
  def setup
    @h = Ractor::LockHash.new(a: 1)
  end

  def assert_acquirable(h, timeout: 3)
    q = Queue.new
    t = Thread.new { h.synchronize { q << :got } }
    assert_not_nil q.pop(timeout: timeout), "LockHash is still held"
    t.join(timeout)
  end

  # --- API ----------------------------------------------------------------

  def test_public_api
    assert_equal %i[[] []= clear delete empty? fetch inspect key? keys size
                    synchronize to_h].sort,
                 Ractor::LockHash.instance_methods(false).sort
  end

  def test_reads
    assert_equal 1, @h[:a]
    assert_nil @h[:z]
    assert_equal 1, @h.size
    assert_false @h.empty?
    assert_true @h.key?(:a)
    assert_false @h.key?(:z)
    assert_equal({ a: 1 }, @h.to_h)
    assert_equal [:a], @h.keys
    assert_equal "#<Ractor::LockHash {a: 1}>", @h.inspect
  end

  def test_fetch
    assert_equal 1, @h.fetch(:a)
    assert_equal :d, @h.fetch(:z, :d)
    assert_equal :z, @h.fetch(:z) { |k| k }
    assert_raise(KeyError) { @h.fetch(:z) }
  end

  def test_snapshots_are_shareable
    assert_true @h.to_h.frozen?
    assert_true Ractor.shareable?(@h.to_h)
    assert_true Ractor.shareable?(@h.keys)
  end

  def test_lockhash_is_frozen_and_shareable
    assert_true @h.frozen?
    assert_true Ractor.shareable?(@h)
    assert_equal 1, Ractor.new(@h) { |h| h[:a] }.value
  end

  def test_empty_by_default
    h = Ractor::LockHash.new
    assert_true h.empty?
    assert_equal({}, h.to_h)
  end

  def test_initial_must_be_shareable
    assert_raise(ArgumentError) { Ractor::LockHash.new(a: []) }
    assert_raise(ArgumentError) { Ractor::LockHash.new([] => 1) }
    assert_raise(TypeError) { Ractor::LockHash.new(1) }
  end

  # --- writes only inside synchronize --------------------------------------

  def test_writes_outside_synchronize_are_refused
    [->{ @h[:b] = 2 }, ->{ @h.delete(:a) }, ->{ @h.clear }].each do |op|
      e = assert_raise(NoMethodError) { op.call }
      assert_match(/only allowed inside Ractor::LockHash#synchronize/, e.message)
    end
    assert_equal({ a: 1 }, @h.to_h, "nothing was written")
  end

  def test_writes_inside_synchronize
    assert_equal 2, @h.synchronize { |h| h[:b] = 2; h[:a] += 1; h.delete(:zz); h[:a] }
    assert_equal({ a: 2, b: 2 }, @h.to_h)
    assert_equal 1, @h.synchronize { |h| h.delete(:b); h.size }
    @h.synchronize(&:clear)
    assert_true @h.empty?
  end

  def test_synchronize_yields_self
    @h.synchronize { |h| assert_same @h, h }
  end

  def test_synchronize_without_block
    assert_raise(LocalJumpError) { @h.synchronize }
  end

  def test_values_must_be_shareable
    assert_raise(ArgumentError) { @h.synchronize { |h| h[:b] = [] } }
    assert_raise(ArgumentError) { @h.synchronize { |h| h[[]] = 1 } }
    assert_equal({ a: 1 }, @h.to_h)
    assert_acquirable @h
  end

  def test_exception_releases_the_lock_and_keeps_earlier_writes
    assert_raise(RuntimeError) { @h.synchronize { |h| h[:b] = 2; raise "boom" } }
    assert_equal({ a: 1, b: 2 }, @h.to_h, "there is no rollback")
    assert_acquirable @h
  end

  def test_synchronize_is_reentrant_on_itself
    assert_equal 4, @h.synchronize { @h.synchronize { @h[:d] = 4 }; @h[:d] }
    assert_acquirable @h
  end

  def test_another_lock_object_inside_is_refused
    lv = Ractor::LockVar.new(0)
    assert_raise(Ractor::NestedLockError) { @h.synchronize { lv.update { 1 } } }
    assert_raise(Ractor::NestedLockError) { lv.update { |v| @h[:b] = 1 } }
    assert_raise(Ractor::NestedLockError) { lv.update { |v| @h.synchronize { } } }
    assert_acquirable @h
  end

  # --- concurrency ----------------------------------------------------------

  def test_updates_are_atomic_across_ractors
    h = Ractor::LockHash.new
    rs = 4.times.map do |i|
      Ractor.new(h, i) { |b, id| 300.times { b.synchronize { |x| x[id] = (x[id] || 0) + 1 } }; :ok }
    end
    rs.each(&:join)
    assert_equal({ 0 => 300, 1 => 300, 2 => 300, 3 => 300 }, h.to_h)
  end

  def test_a_reader_never_sees_a_half_done_section
    h = Ractor::LockHash.new(x: 0, y: 0)
    stop = Ractor::LockVar.new(false)
    seen = Queue.new
    running = Queue.new

    readers = 2.times.map do
      Thread.new do
        running << :up
        until stop.value
          seen << h.to_h
          Thread.pass          # the lock is not fair; let the writer in
        end
      end
    end
    2.times { running.pop(timeout: 5) or flunk "readers did not start" }

    300.times do |i|
      h.synchronize { |b| b[:x] = i; Thread.pass; b[:y] = i }   # x and y always agree
      sleep 0.0002
    end
    stop.update { true }
    readers.each { |t| t.join(10) or flunk "reader hung" }

    snapshots = []
    snapshots << seen.pop until seen.empty?
    assert_operator snapshots.size, :>, 100
    assert_empty snapshots.reject { |s| s[:x] == s[:y] }
  end

  def test_killing_the_holder_releases_the_lock
    h = Ractor::LockHash.new
    q = Queue.new
    holder = Thread.new { h.synchronize { q << :held; sleep 5 } }
    q.pop
    holder.kill
    holder.join(3)
    assert_acquirable h
  end

  def test_killing_a_waiter_leaves_the_lock_alone
    h = Ractor::LockHash.new
    q = Queue.new
    holder = Thread.new { h.synchronize { q << :held; sleep 0.3 } }
    q.pop
    waiters = 3.times.map { Thread.new { h.synchronize { } } }
    sleep 0.05
    waiters.each(&:kill)
    waiters.each { |t| t.join(3) or flunk "a blocked waiter could not be killed" }
    holder.join(3)
    assert_acquirable h
  end
end
