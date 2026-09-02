# frozen_string_literal: true

require_relative "test_helper"

class KeyLockHashTest < Test::Unit::TestCase
  def setup
    @m = Ractor::KeyLockHash.new(a: 1)
  end

  # --- API ----------------------------------------------------------------

  def test_public_api
    assert_equal %i[[] []= delete fetch inspect key? keys to_h update].sort,
                 Ractor::KeyLockHash.instance_methods(false).sort
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

  def test_keys_and_values_must_be_shareable
    assert_raise(ArgumentError) { Ractor::KeyLockHash.new(k: []) }
    assert_raise(ArgumentError) { @m[:x] = [] }
    assert_raise(ArgumentError) { @m["mutable key".dup] = 1 }
    assert_raise(ArgumentError) { @m.update("mutable key".dup) { 1 } }
    assert_raise(ArgumentError) { @m.update(:x) { [] } }
    assert_false @m.key?(:x), "a rejected update must not leave the key behind"
  end

  def test_no_second_key_inside_update
    e = assert_raise(Ractor::NestedLockError) { @m.update(:a) { @m[:other] } }
    assert_match(/LockHash/, e.message, "the message points at the multi-key tool")
    assert_equal 1, @m[:a]
    other = Ractor::LockVar.new(0)
    assert_raise(Ractor::NestedLockError) { other.update { @m[:a] } }
  end

  def test_a_key_callback_raises_instead_of_deadlocking
    map = Ractor::KeyLockHash.new
    probing = Class.new do
      def initialize(m) = @m = m
      def hash = (@m[:probe]; 1)
      def eql?(o) = equal?(o)
    end
    key = Ractor.make_shareable(probing.new(map))
    t = Thread.new { map[key] rescue $! }
    assert_not_nil t.join(3), "a key callback into the same map deadlocked"
    assert_kind_of Ractor::NestedLockError, t.value
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
    assert_equal 7, @m.update(:a) { 7 }, "a killed holder stranded the shard"
  end
end
