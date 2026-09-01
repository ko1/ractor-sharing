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
    assert_equal %i[[] []= clear delete fetch inspect key? keys
                    synchronize to_h].sort,
                 Ractor::LockHash.instance_methods(false).sort
  end

  def test_reads
    assert_equal 1, @h[:a]
    assert_nil @h[:z]
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

  # A key's #hash runs while the lock is held, and it is ordinary Ruby that can
  # reach back into the hash. Without the held marker that inner read waited for
  # a lock its own frame held, and never returned.
  class ReentrantKey
    def initialize(hash) = @hash = hash
    def hash = (@hash[:probe]; 1)
    def eql?(other) = other.is_a?(ReentrantKey)
  end

  def test_a_key_callback_may_read_the_same_hash
    h = Ractor::LockHash.new
    key = Ractor.make_shareable(ReentrantKey.new(h))
    t = Thread.new { h[key] }
    assert_not_nil t.join(3), "a key callback reading the same hash deadlocked"
    assert_nil t.value
  end

  def test_a_key_callback_reaching_for_another_lock_is_refused
    other = Ractor::LockHash.new
    key = Ractor.make_shareable(ReentrantKey.new(other))
    h = Ractor::LockHash.new
    t = Thread.new do
      h[key]
    rescue Ractor::NestedLockError
      :refused
    end
    assert_not_nil t.join(3), "a key callback taking a second lock deadlocked"
    assert_equal :refused, t.value
    assert_acquirable h
    assert_acquirable other
  end

  def test_fetch_default_runs_outside_the_lock
    # Held, a block that touched this hash again would wait on a lock its own
    # frame holds. It used to; the block now runs after the lookup releases it.
    h = Ractor::LockHash.new
    t = Thread.new { h.fetch(:missing) { h.synchronize { |x| x[:made] = 1 }; :from_block } }
    assert_equal :from_block, t.value if assert_not_nil t.join(3), "fetch deadlocked"
    assert_equal 1, h[:made]

    t = Thread.new { h.fetch(:missing) { h[:made] } }
    assert_equal 1, t.value if assert_not_nil t.join(3), "fetch deadlocked on a read"
  end

  def test_initialize_cannot_be_rerun
    assert_raise(FrozenError) { @h.send(:initialize, b: 2) }
    assert_equal({ a: 1 }, @h.to_h)
  end

  def test_fetch_prefers_the_block_over_the_default
    assert_equal :from_block, @h.fetch(:z, :from_default) { :from_block }
  end

  def test_snapshots_are_plain_detached_copies
    snap = @h.to_h
    assert_false snap.frozen?, "the copy is the caller's own, not frozen"
    snap[:b] = 2
    assert_equal({ a: 1 }, @h.to_h, "reshaping the copy does not reach the hash"
    )
    ks = @h.keys
    assert_false ks.frozen?
    ks << :zz
    assert_equal [:a], @h.keys
  end

  def test_lockhash_is_frozen_and_shareable
    assert_true @h.frozen?
    assert_true Ractor.shareable?(@h)
    assert_equal 1, Ractor.new(@h) { |h| h[:a] }.value
  end

  def test_empty_by_default
    assert_equal({}, Ractor::LockHash.new.to_h)
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
    assert_equal [:a], @h.synchronize { |h| h.delete(:b); h.keys }
    @h.synchronize(&:clear)
    assert_equal({}, @h.to_h)
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
