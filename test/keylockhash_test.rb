# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class KeyLockHashTest < Test::Unit::TestCase
  def setup
    @m = Ractor::KeyLockHash.new(a: 1)
  end

  # --- API ----------------------------------------------------------------

  def test_public_api
    assert_equal %i[[] []= delete fetch store_if_absent increment inspect key? keys to_h update].sort,
                 Ractor::KeyLockHash.instance_methods(false).sort
  end

  def test_store_if_absent
    runs = 0
    assert_equal 10, @m.store_if_absent(:new) { runs += 1; 10 }   # miss computes
    assert_equal 10, @m.store_if_absent(:new) { runs += 1; 99 }   # hit skips block
    assert_equal 1, runs, "the block ran only on the miss"
    assert_equal 1, @m.store_if_absent(:a) { 99 }, "existing key is returned untouched"
    assert_raise(LocalJumpError) { @m.store_if_absent(:x) }
    assert_true @m.store_if_absent(:arr) { [1] }.frozen?, "computed value made shareable"
  end

  def test_store_if_absent_treats_nil_as_absent
    runs = 0
    assert_nil @m.store_if_absent(:n) { runs += 1; nil }  # nil result is not cached
    assert_nil @m.store_if_absent(:n) { runs += 1; nil }  # so it runs again
    assert_equal 2, runs, "a nil result is treated as absent, not a cached hit"
    @m[:e] = nil                                          # an explicitly stored nil
    assert_equal 7, @m.store_if_absent(:e) { 7 }, "a stored nil counts as absent too"
  end

  def test_store_if_absent_computes_once_under_contention
    # The block holds the key's lock, so it must not take a second lock -- the
    # count of who computed rides in the stored value instead.
    m = Ractor::KeyLockHash.new
    rs = 8.times.map do |i|
      Ractor.new(m, i) { |x, id| x.store_if_absent(:k) { [:by, id, rand] } }
    end
    results = rs.map(&:value)
    assert_equal 1, results.uniq.size, "all eight saw the one stored value"
    assert_equal :by, results.first.first
  end

  def test_store_if_absent_blocks_on_different_keys_run_in_parallel
    m = Ractor::KeyLockHash.new
    ready = Ractor::Port.new
    rs = 2.times.map do |i|
      Ractor.new(m, ready, i) do |x, port, id|
        x.store_if_absent(id) do
          gate = Ractor::Port.new
          port << [id, gate]
          gate.receive
          id
        end
      end
    end

    gates = []
    begin
      entered = 2.times.map do
        id, gate = Timeout.timeout(2) { ready.receive }
        gates << gate
        id
      end
      assert_equal [0, 1], entered.sort,
                   "a computation for one missing key must not hold the structural lock"
    ensure
      gates.each { |gate| gate << true }
    end
    assert_equal [0, 1], rs.map(&:value).sort
  end

  def test_reads
    assert_equal 1, @m[:a]
    assert_nil @m[:zz]
    assert_true @m.key?(:a)
    assert_false @m.key?(:zz)
    assert_equal [:a], @m.keys
    assert_equal({ a: 1 }, @m.to_h)
    assert_equal "#<Ractor::KeyLockHash {a: 1}>", @m.inspect
  end

  def test_fetch
    assert_equal 1, @m.fetch(:a)
    assert_equal :d, @m.fetch(:z, :d)
    assert_equal :z, @m.fetch(:z) { |k| k }
    assert_equal :from_block, @m.fetch(:z, :from_default) { :from_block }
    assert_raise(KeyError) { @m.fetch(:z) }
  end

  def test_plain_writes
    @m[:b] = 2
    assert_equal 2, @m[:b]
    assert_equal 3, (@m[:b] = 3)
    assert_equal 3, @m.delete(:b)
    assert_nil @m.delete(:b)
  end

  def test_update_computes_from_the_old_value
    assert_equal 2, @m.update(:a) { |v| v + 1 }
    assert_equal :made, @m.update(:new) { |v| v.nil? ? :made : v }
    assert_equal :made, @m[:new]
  end

  def test_increment
    assert_equal 1, @m.increment(:hits), "a missing key counts as zero"
    assert_equal 6, @m.increment(:hits, 5)
    assert_equal 4, @m.increment(:hits, -2)
    assert_equal 2, @m.increment(:a), "an existing value is added to"
    assert_raise(TypeError) { @m.increment(:hits, nil) }
    assert_equal 4, @m[:hits]
  end

  def test_increment_crosses_the_fixnum_boundary
    max = 2**(0.size * 8 - 2) - 1
    @m[:big] = max
    assert_equal max + 1, @m.increment(:big)
    assert_equal max + 2, @m.increment(:big)
  end

  def test_increment_on_a_value_without_plus
    @m[:sym] = :oops
    assert_raise(NoMethodError) { @m.increment(:sym) }
    assert_equal :oops, @m[:sym]
    assert_equal 1, @m.increment(:sym2), "the entry claim survived the raise"
  end

  def test_increment_is_atomic_across_ractors
    m = Ractor::KeyLockHash.new
    rs = 8.times.map do |i|
      Ractor.new(m, i) do |x, id|
        300.times { x.increment("own-#{id}".freeze) }
        300.times { x.increment(:shared) }
        :ok
      end
    end
    rs.each(&:join)
    8.times { |i| assert_equal 300, m["own-#{i}"] }
    assert_equal 2400, m[:shared]
  end

  def test_increment_inside_update_is_refused
    assert_raise(Ractor::NestedLockError) { @m.update(:a) { @m.increment(:b) } }
    assert_nil @m[:b]
  end

  def test_the_claim_idiom
    mine = []
    2.times { |i| @m.update(:job) { |v| v || (mine << i; :claimed) } }
    assert_equal [0], mine, "only the request that saw nil claimed it"
  end

  def test_snapshots_are_plain_detached_copies
    snap = @m.to_h
    assert_false snap.frozen?
    snap[:x] = 9
    assert_equal({ a: 1 }, @m.to_h)
  end

  # --- rules ----------------------------------------------------------------

  def test_values_are_made_shareable_and_keys_must_be
    assert_true Ractor::KeyLockHash.new(k: [])[:k].frozen?
    arr = [1, [2]]
    @m[:x] = arr
    assert_true arr.frozen? && arr[1].frozen?, "deep-frozen in place"
    assert_equal [1, [2], 2], @m.update(:x) { |v| v + [2] }
    assert_true @m[:x].frozen?
    assert_raise(ArgumentError) { @m[[1]] = 1 }
  end

  def test_a_bare_string_key_is_dupped_and_frozen_like_hash
    mine = String.new("order-1")
    @m[mine] = 1
    @m.update(String.new("order-2")) { 2 }
    stored = @m.keys.grep(/order/).sort
    assert_equal %w[order-1 order-2], stored
    assert_true stored.all?(&:frozen?)
    assert_false mine.frozen?, "the caller's string stays their own"
    assert_false stored.any? { |k| k.equal?(mine) }
    assert_equal 1, @m["order-1"]
    m2 = Ractor::KeyLockHash.new(String.new("k") => 1)
    assert_equal 1, m2["k"]
  end

  def test_no_second_key_inside_update
    e = assert_raise(Ractor::NestedLockError) { @m.update(:a) { @m[:other] } }
    assert_match(/LockHash/, e.message, "the message points at the multi-key tool")
    assert_equal 1, @m[:a]
    other = Ractor::LockVar.new(0)
    assert_raise(Ractor::NestedLockError) { other.update { @m[:a] } }
  end

  def test_a_key_callback_that_reads_the_map_does_not_deadlock
    # A read takes no lock (RCU), so a key whose #hash reads the same map is
    # safe -- it neither deadlocks (the old st bug) nor has to raise: the inner
    # read just runs.
    map = Ractor::KeyLockHash.new
    probing = Class.new do
      def initialize(m) = @m = m
      def hash; @m[:probe]; 1; end
      def eql?(o) = equal?(o)
    end
    key = Ractor.make_shareable(probing.new(map))
    map[:probe] = :ok
    t = Thread.new { map[key] }
    assert_not_nil t.join(3), "a key callback into the same map deadlocked"
    assert_nil t.value, "the key is absent; the callback's own read saw :probe"
  end

  def test_initialize_cannot_be_rerun
    assert_raise(FrozenError) { @m.send(:initialize, b: 2) }
    assert_equal({ a: 1 }, @m.to_h)
  end

  def test_it_is_frozen_and_shareable
    assert_true @m.frozen?
    assert_true Ractor.shareable?(@m)
  end

  # --- across Ractors -------------------------------------------------------

  def test_per_key_updates_do_not_lose_counts
    m = Ractor::KeyLockHash.new
    rs = 8.times.map do |i|
      Ractor.new(m, i) do |x, id|
        400.times { x.update("own-#{id}".freeze) { |v| (v || 0) + 1 } }
        400.times { x.update(:shared) { |v| (v || 0) + 1 } }
        :ok
      end
    end
    rs.each(&:join)
    8.times { |i| assert_equal 400, m["own-#{i}"] }
    assert_equal 3200, m[:shared]
  end

  def test_exceptions_release_the_key
    assert_raise(RuntimeError) { @m.update(:a) { raise "boom" } }
    assert_equal 1, @m[:a]
    assert_equal 5, @m.update(:a) { 5 }

    q = Queue.new
    t = Thread.new { @m.update(:a) { q << :in; sleep 5; 9 } }
    q.pop
    t.kill
    t.join
    assert_equal 7, @m.update(:a) { 7 }, "a killed holder stranded the entry"
  end

  def test_plain_writer_parks_behind_an_update_block
    entered = Queue.new
    release = Queue.new
    owner = Thread.new do
      @m.update(:a) { entered << true; release.pop; 2 }
    end
    entered.pop

    started = Queue.new
    writer = Thread.new do
      started << true
      @m[:a] = 3
    end
    started.pop
    Thread.pass
    assert_true writer.alive?, "the assignment must wait for the claimed entry"

    release << true
    assert_not_nil owner.join(2)
    assert_not_nil writer.join(2), "a Port waiter was not woken by commit"
    assert_equal 3, @m[:a]
  ensure
    release << true if owner&.alive?
    owner&.join(2)
    writer&.join(2)
  end

  def test_exception_rolls_back_and_wakes_a_waiting_writer
    entered = Queue.new
    release = Queue.new
    owner = Thread.new do
      @m.update(:a) do
        entered << true
        release.pop
        raise "boom"
      end
    rescue RuntimeError => error
      error.message
    end
    entered.pop

    writer = Thread.new { @m[:a] = 3 }
    Timeout.timeout(2) do
      Thread.pass until writer.status == "sleep"
    end

    release << true
    assert_equal "boom", owner.value
    assert_not_nil writer.join(2), "rollback did not wake the Port waiter"
    assert_equal 3, @m[:a]
  ensure
    release << true if owner&.alive?
    owner&.join(2)
    writer&.join(2)
  end

  def test_resize_does_not_move_a_claimed_entry
    m = Ractor::KeyLockHash.new
    16.times { |i| m[i] = i }
    entered = Queue.new
    release = Queue.new
    owner = Thread.new do
      m.update(0) { |old| entered << true; release.pop; old + 1 }
    end
    entered.pop

    2_000.times { |i| m[100 + i] = i }
    release << true
    assert_not_nil owner.join(2)
    assert_equal 1, m[0]
    assert_equal 2_016, m.keys.size
  ensure
    release << true if owner&.alive?
    owner&.join(2)
  end

end
