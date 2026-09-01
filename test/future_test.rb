# frozen_string_literal: true

require_relative "test_helper"

class TestFuture < Test::Unit::TestCase
  include RactorHelper

  class Worker < Ractor::ActiveObject
    future def compute(x) = x * 2
    future def fail_it = raise(KeyError, "nope")
  end

  def test_value_from_another_ractor
    w = Worker.new
    assert_equal 42, in_ractor(w) { |o| o.compute(21).value }
  end

  def test_inspect_and_states
    f = Worker.new.compute(1)
    assert_match(/pending/, f.inspect)
    f.wait
    assert_match(/fulfilled/, f.inspect)
    g = Worker.new.fail_it
    assert_raise(KeyError) { g.value }
    assert_match(/rejected/, g.inspect)
  end

  def test_future_value_from_multiple_threads
    f = Worker.new.compute(5)
    assert_equal [10] * 4, 4.times.map { Thread.new { f.value } }.map(&:value)
  end

  def test_local_future_send_on_owner
    klass = Class.new(Ractor::ActiveObject) do
      sync def go = [future_send(:itself).value.equal?(self), future_send(:nope).rejected?]
    end
    assert_equal [true, true], klass.new.go
  end
end
