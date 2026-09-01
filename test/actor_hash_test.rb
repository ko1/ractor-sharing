# frozen_string_literal: true

require_relative "test_helper"

class ActorHashTest < Test::Unit::TestCase
  include RactorHelper

  def setup
    @h = Ractor::ActorHash.new(a: 1)
  end

  def test_the_api_reads_directly_but_writes_through_a_block
    api = (Ractor::ActorHash::Proxy.instance_methods - Object.instance_methods).sort
    assert_equal %i[[] active_object_class async_call async_send call fetch
                    future_call future_send increment key? keys set sync_send
                    to_h].sort, api
    assert_not_include api, :[]=, "every change goes through a call"
    assert_not_include api, :delete
    assert_not_include api, :clear
  end

  def test_reads
    assert_equal 1, @h[:a]
    assert_nil @h[:zz]
    assert_true @h.key?(:a)
    assert_false @h.key?(:zz)
    assert_equal [:a], @h.keys
    assert_equal({ a: 1 }, @h.to_h)
  end

  def test_fetch
    assert_equal 1, @h.fetch(:a)
    assert_equal :d, @h.fetch(:zz, :d)
    assert_equal :zz, @h.fetch(:zz) { |k| k }
    e = assert_raise(KeyError) { @h.fetch(:zz) }
    assert_equal :zz, e.key
  end

  def test_fetch_tells_a_stored_nil_from_a_missing_key
    @h.async_call { |h| h[:nil] = nil }
    assert_nil @h.fetch(:nil)
    assert_raise(KeyError) { @h.fetch(:nope) }
  end

  def test_call_runs_on_the_owner_and_returns_its_value
    assert_equal 1, @h.call { |h| h[:a] }
    assert_equal 2, @h.call { |h| h[:a] += 1 }
    assert_equal({ a: 2 }, @h.to_h)
  end

  def test_call_takes_arguments
    assert_equal 11, @h.call(10) { |h, n| h[:a] += n }
  end

  def test_initial_is_copied_not_captured
    src = { a: 1 }
    h = Ractor::ActorHash.new(src)
    src[:b] = 2
    assert_equal({ a: 1 }, h.to_h)
  end

  def test_empty_by_default
    assert_equal({}, Ractor::ActorHash.new.to_h)
  end

  def test_inspect
    assert_equal "#<Ractor::ActorHash {a: 1}>", @h.inspect
  end

  # --- set / increment ------------------------------------------------------

  def test_set
    assert_nil @h.set(:b, 2), "sent, not waited for"
    assert_equal 2, @h[:b]
    @h.set(:b, [1, 2])
    assert_equal [1, 2], @h[:b], "any value, not only shareable ones"
  end

  def test_increment
    assert_nil @h.increment(:n)
    assert_equal 1, @h[:n]
    @h.increment(:n, 5)
    @h.increment(:n, -2)
    assert_equal 4, @h[:n]
    @h.increment(:a)
    assert_equal 2, @h[:a], "an existing value is added to"
  end

  # The reason these exist at all: arguments travel as arguments, so they are
  # not held to what an isolated block may capture.
  def test_set_takes_values_a_block_could_not_capture
    key = :x
    key = :y
    value = [1]
    value = [1, 2]
    assert_raise(Ractor::IsolationError) { @h.async_call { |h| h[key] = value } }
    assert_nil @h.set(key, value)
    assert_equal [1, 2], @h[:y]
  end

  def test_increment_of_a_value_that_cannot_be_added_to
    @h.set(:sym, :not_a_number)
    @h.increment(:sym)                    # async: the owner reports it and carries on
    assert_equal :not_a_number, @h[:sym]
    assert_equal 1, @h[:a], "the owner is still serving"
  end

  # --- what it is for -------------------------------------------------------

  def test_values_need_not_be_shareable
    @h.async_call { |h| h[:list] = [1, 2] }
    assert_equal 3, @h.call { |h| h[:list] << 3; h[:list].size }
    assert_equal [1, 2, 3], @h[:list]
  end

  def test_the_block_gets_the_real_hash_and_cannot_leak_it
    got = @h.call { |h| h[:list] = [1]; h }
    assert_equal({ a: 1, list: [1] }, got)
    got[:sneaked] = true
    assert_equal({ a: 1, list: [1] }, @h.to_h, "what came back was a copy")
    assert_true @h.call { |h| h.respond_to?(:merge!) }, "it really is a Hash"
  end

  # --- the block ------------------------------------------------------------

  def test_a_local_that_is_never_reassigned_is_captured
    v = 1
    assert_equal 2, @h.call { |h| h[:a] + v }
  end

  # Whether a variable "may be reassigned" is decided from the whole scope, not
  # from what has happened so far, so one later assignment rules the block out.
  def test_a_local_that_is_reassigned_is_refused
    v = 1
    assert_raise(Ractor::IsolationError) { @h.call { |h| h[:a] + v } }
    v = 2
    assert_equal 2, v
  end

  def test_call_without_block
    assert_raise(LocalJumpError) { @h.call }
    assert_raise(LocalJumpError) { @h.async_call }
    assert_raise(LocalJumpError) { @h.future_call }
  end

  # --- policies -------------------------------------------------------------

  def test_call_propagates_exceptions
    e = assert_raise(RuntimeError) { @h.call { raise "boom" } }
    assert_equal "boom", e.message
    assert_equal 1, @h[:a], "the owner is still serving"
  end

  def test_future_call
    f = @h.future_call { |h| h[:a] + 1 }
    assert_kind_of Ractor::ActiveObject::Future, f
    assert_equal 2, f.value
    assert_raise(RuntimeError) { @h.future_call { raise "boom" }.value }
  end

  def test_async_call_returns_nil_and_lands_before_the_next_call
    assert_nil @h.async_call { |h| h[:done] = true }
    assert_equal true, @h[:done]
  end

  def test_calls_are_ordered_and_serialized
    100.times { |i| @h.async_call(i) { |h, n| (h[:seen] ||= []) << n } }
    assert_equal (0...100).to_a, @h[:seen]
  end

  # --- across Ractors -------------------------------------------------------

  def test_shareable_and_usable_from_other_ractors
    assert_true Ractor.shareable?(@h)
    assert_equal 1, in_ractor(@h) { |h| h[:a] }
  end

  def test_updates_from_several_ractors_are_serialized
    h = Ractor::ActorHash.new(n: 0)
    rs = 4.times.map { Ractor.new(h) { |x| 200.times { x.async_call { |db| db[:n] += 1 } }; :ok } }
    rs.each(&:join)
    assert_equal 800, h[:n]
  end
end
