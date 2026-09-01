# frozen_string_literal: true

require_relative "test_helper"

class ActorHashTest < Test::Unit::TestCase
  include RactorHelper

  def setup
    @h = Ractor::ActorHash.new(a: 1)
  end

  def test_reads
    assert_equal 1, @h[:a]
    assert_nil @h[:zz]
    assert_equal 1, @h.size
    assert_false @h.empty?
    assert_true @h.key?(:a)
    assert_false @h.key?(:zz)
    assert_equal [:a], @h.keys
    assert_equal({ a: 1 }, @h.to_h)
    assert_equal "#<Ractor::ActorHash {a: 1}>", @h.inspect
  end

  def test_writes
    @h[:b] = 2
    assert_equal({ a: 1, b: 2 }, @h.to_h)
    assert_equal 1, @h.delete(:a)
    assert_nil @h.delete(:gone)
    assert_nil @h.clear
    assert_true @h.empty?
  end

  def test_fetch
    assert_equal 1, @h.fetch(:a)
    assert_equal :d, @h.fetch(:zz, :d)
    assert_equal :zz, @h.fetch(:zz) { |k| k }
    e = assert_raise(KeyError) { @h.fetch(:zz) }
    assert_equal :zz, e.key
  end

  def test_fetch_tells_a_stored_nil_from_a_missing_key
    @h[:nil] = nil
    assert_nil @h.fetch(:nil)
    assert_raise(KeyError) { @h.fetch(:nope) }
  end

  def test_empty_by_default
    h = Ractor::ActorHash.new
    assert_true h.empty?
    assert_equal({}, h.to_h)
  end

  def test_initial_is_copied_not_captured
    src = { a: 1 }
    h = Ractor::ActorHash.new(src)
    src[:b] = 2
    assert_equal({ a: 1 }, h.to_h)
  end

  # --- what it is for -------------------------------------------------------

  def test_values_need_not_be_shareable
    @h[:list] = [1, 2]
    assert_equal [1, 2], @h[:list]
    assert_equal 3, @h.call { |db| db[:list] << 3; db[:list].size }
    assert_equal [1, 2, 3], @h[:list]
  end

  def test_a_value_that_comes_back_is_a_copy
    @h[:list] = [1]
    got = @h[:list]
    got << :not_stored
    assert_equal [1], @h[:list]
  end

  def test_call_runs_on_the_owner_and_returns_its_value
    assert_equal 2, @h.call { |db| db[:a] += 1 }
    assert_equal 2, @h[:a]
    assert_equal false, @h.call { |db| db.equal?(nil) }
  end

  def test_call_takes_arguments
    assert_equal 11, @h.call(10) { |db, n| db[:a] += n }
  end

  def test_a_local_that_is_never_reassigned_is_captured
    v = 1
    assert_equal 2, @h.call { |db| db[:a] + v }
  end

  # Whether a variable "may be reassigned" is decided from the whole scope, not
  # from what has happened so far, so one later assignment rules the block out.
  def test_a_local_that_is_reassigned_is_refused
    v = 1
    assert_raise(Ractor::IsolationError) { @h.call { |db| db[:a] + v } }
    v = 2
    assert_equal 2, v
  end

  def test_call_without_block
    assert_raise(LocalJumpError) { @h.call }
    assert_raise(LocalJumpError) { @h.async_call }
    assert_raise(LocalJumpError) { @h.future_call }
  end

  def test_call_propagates_exceptions
    e = assert_raise(RuntimeError) { @h.call { raise "boom" } }
    assert_equal "boom", e.message
    assert_equal 1, @h[:a], "the owner is still serving"
  end

  def test_future_call
    f = @h.future_call { |db| db[:a] + 1 }
    assert_kind_of Ractor::ActiveObject::Future, f
    assert_equal 2, f.value
    assert_raise(RuntimeError) { @h.future_call { raise "boom" }.value }
  end

  def test_async_call
    assert_nil @h.async_call { |db| db[:done] = true }
    assert_equal true, @h.call { |db| db[:done] }, "the earlier call landed first"
  end

  def test_calls_are_ordered_and_serialized
    100.times { |i| @h.async_call(i) { |db, n| db[:seen] = (db[:seen] || []) << n } }
    assert_equal (0...100).to_a, @h.call { |db| db[:seen] }
  end

  # --- across Ractors -------------------------------------------------------

  def test_shareable_and_usable_from_other_ractors
    assert_true Ractor.shareable?(@h)
    assert_equal 1, in_ractor(@h) { |h| h[:a] }
    assert_equal 2, in_ractor(@h) { |h| h.call { |db| db[:a] + 1 } }
  end

  def test_updates_from_several_ractors_are_serialized
    h = Ractor::ActorHash.new(n: 0)
    rs = 4.times.map { Ractor.new(h) { |x| 200.times { x.call { |db| db[:n] += 1 } }; :ok } }
    rs.each(&:join)
    assert_equal 800, h[:n]
  end

  def test_owner
    assert_kind_of Ractor, @h.owner
    assert_not_same Ractor.current, @h.owner
  end
end
