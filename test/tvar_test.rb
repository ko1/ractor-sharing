# frozen_string_literal: true

require_relative "test_helper"

class Ractor::TVarTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Ractor::Sharing.const_defined?(:VERSION)
    end
  end

  test 'Ractor::TVar can has a value' do
    tv = Ractor::TVar.new(1)
    assert_equal 1, tv.value
  end

  test 'Ractor::TVar without initial value will return nil' do
    tv = Ractor::TVar.new
    assert_equal nil, tv.value
  end

  test 'Ractor::TVar can change the value' do
    tv = Ractor::TVar.new
    assert_equal nil, tv.value
    Ractor::atomically do
      tv.value = :ok
    end
    assert_equal :ok, tv.value
  end

  test 'Ractor::TVar update without atomically will raise an exception' do
    tv = Ractor::TVar.new
    assert_raise  Ractor::TransactionError do
      tv.value = :ng
    end
  end

  test 'Ractor::TVar#increment increments the value' do
    tv = Ractor::TVar.new(0)
    tv.increment
    assert_equal 1, tv.value

    tv.increment 2
    assert_equal 3, tv.value

    Ractor::atomically do
      tv.increment 3
    end
    assert_equal 6, tv.value

    Ractor::atomically do
      tv.value = 1.5
    end
    tv.increment(-1.5)
    assert_equal 0.0, tv.value
  end

  test 'Ractor::TVar can not set the unshareable value' do
    assert_raise ArgumentError do
      Ractor::TVar.new [1]
    end
  end

  ## with Ractors
  N = 10_000
  test 'Ractor::TVar consistes with other Ractors' do
    tv = Ractor::TVar.new(0)
    rs = 4.times.map{
      Ractor.new tv do |tv|
        N.times{ Ractor::atomically{ tv.increment } }
      end
    }
    rs.each{|r| r.value}
    assert_equal N * 4 , tv.value
  end

  # --- what the documentation promises -------------------------------------

  test "only shareable values are allowed" do
    assert_raise(ArgumentError) { Ractor::TVar.new([]) }
    tv = Ractor::TVar.new(0)
    assert_raise(ArgumentError) { Ractor.atomically { tv.value = [] } }
    assert_equal 0, tv.value, "a rejected write leaves the value alone"
    Ractor.atomically { tv.value = [1].freeze }
    assert_equal [1], tv.value
  end

  # What is allowed outside a transaction. The API section of the documentation
  # is the one part a running example cannot check, so it is checked here.
  test "a write needs a transaction, a read and an increment do not" do
    tv = Ractor::TVar.new(0)

    assert_equal 0, tv.value, "a read outside a transaction is allowed"

    e = assert_raise(Ractor::TransactionError) { tv.value = 1 }
    assert_equal "can not set without transaction", e.message
    assert_equal 0, tv.value, "and it wrote nothing"

    assert_equal 1, tv.increment, "increment outside a transaction is allowed"
    assert_equal 2, Ractor.atomically { tv.value = tv.value + 1 }
    assert_equal 2, tv.value
  end

  test "increment rejects an unshareable sum, inside a transaction as well as out" do
    # The in-transaction path called + and stored whatever came back. A TVar only
    # ever holds shareable values, and the sum of two frozen arrays is not one.
    tv = Ractor::TVar.new([1].freeze)
    assert_raise(ArgumentError) { Ractor.atomically { tv.increment([2].freeze) } }
    assert_equal [1], tv.value
    assert_raise(ArgumentError) { tv.increment([2].freeze) }
    assert_equal [1], tv.value
  end

  test "increment adds in one step" do
    tv = Ractor::TVar.new(1)
    assert_equal 2, tv.increment
    assert_equal 7, tv.increment(5)
    assert_equal 5, tv.increment(-2)
    assert_equal 5, tv.value
  end

  test "a transaction is all or nothing" do
    from = Ractor::TVar.new(100)
    to   = Ractor::TVar.new(0)
    Ractor.atomically { from.value -= 10; to.value += 10 }
    assert_equal [90, 10], [from.value, to.value]

    assert_raise(RuntimeError) do
      Ractor.atomically { from.value -= 10; raise "boom" }
    end
    assert_equal 90, from.value, "the half that ran was rolled back"
  end

  test "a TVar is shareable and usable from another Ractor" do
    tv = Ractor::TVar.new(1)
    assert_true Ractor.shareable?(tv)
    assert_equal 2, Ractor.new(tv) { |t| Ractor.atomically { t.value += 1 } }.value
    assert_equal 2, tv.value
  end

  test "several Ractors updating one TVar lose nothing" do
    tv = Ractor::TVar.new(0)
    rs = 4.times.map { Ractor.new(tv) { |t| 500.times { Ractor.atomically { t.value += 1 } }; :ok } }
    rs.each(&:join)
    assert_equal 2000, tv.value
  end

  test "several Ractors keep two TVars in step" do
    a = Ractor::TVar.new(0)
    b = Ractor::TVar.new(0)
    rs = 4.times.map do
      Ractor.new(a, b) { |x, y| 300.times { Ractor.atomically { x.value += 1; y.value -= 1 } }; :ok }
    end
    rs.each(&:join)
    assert_equal [1200, -1200], [a.value, b.value]
    assert_equal 0, a.value + b.value
  end

  # The counter is a LockVar on purpose: a TVar would join the transaction and
  # be rolled back with it, counting commits rather than runs. This is the
  # documented hazard itself -- a side effect in the block happens again on
  # every retry.
  test "a block may run more than once, so keep it free of side effects" do
    runs = Ractor::LockVar.new(0)
    tv = Ractor::TVar.new(0)
    rs = 4.times.map do
      Ractor.new(tv, runs) do |t, r|
        200.times { Ractor.atomically { r.increment; t.value += 1 } }
        :ok
      end
    end
    rs.each(&:join)
    assert_equal 800, tv.value, "every increment landed exactly once"
    assert_operator runs.value, :>, 800, "and the block ran more often than that"
  end

  test "the transaction errors exist" do
    assert_operator Ractor::TransactionError, :<, RuntimeError
    assert_operator Ractor::RetryTransaction, :<, Exception
  end
end
