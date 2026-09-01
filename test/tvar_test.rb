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

  test "replacing the transaction thread-local mid-transaction does not crash" do
    # The transaction log lives in a Ruby-writable thread local, and the C side
    # threads a raw pointer to it through the transaction. Overwriting the local
    # used to leave that pointer as the only reference, so a GC freed the log
    # out from under the commit. The object is pinned for the transaction now;
    # sabotage gets an exception at worst, never freed memory.
    t = Thread.new do
      tv = Ractor::TVar.new(0)
      10.times do
        begin
          Ractor.atomically do
            tv.value = tv.value + 1
            Thread.current[:__ractor_tvar_tls__] = nil
            GC.start(full_mark: true, immediate_sweep: true)
            tv.value = tv.value + 1
          end
        rescue Ractor::TransactionError
          # the fresh, disabled log refuses the write: acceptable
        end
      end
      :ok
    end
    assert_equal :ok, t.value
  end

  test "direct increments and transactions on the same TVar do not lose updates" do
    # increment outside a transaction takes the slot lock and a version; the
    # unlocked version-clock re-store it used to do could roll the clock back
    # over a concurrent commit and let a stale read pass validation.
    tv = Ractor::TVar.new(0)
    other = Ractor::TVar.new(0)
    rs = 2.times.map { Ractor.new(tv) { |t| 5_000.times { t.increment }; :ok } }
    rs += 2.times.map do
      Ractor.new(tv, other) do |t, o|
        5_000.times { Ractor.atomically { o.value += 1; t.value += 1 } }
        :ok
      end
    end
    rs.each(&:join)
    assert_equal 20_000, tv.value
    assert_equal 10_000, other.value
  end

  test "a TVar is frozen, so shareable means what it says" do
    # The shareable flag used to be set by hand, which left the TVar shareable
    # but not frozen: the main Ractor could go on attaching ivars to an object
    # other Ractors were holding.
    tv = Ractor::TVar.new(1)
    assert_true tv.frozen?
    assert_true Ractor.shareable?(tv)
    assert_raise(FrozenError) { tv.instance_variable_set(:@x, []) }

    # and it still works as a variable
    Ractor.atomically { tv.value = 5 }
    assert_equal 6, tv.increment
    assert_equal 7, Ractor.new(tv) { |t| t.increment; t.value }.value
  end

  test "a TVar with no slot yet, and a forged transaction log, raise instead of crashing" do
    # Both took a raw DATA_PTR of whatever they were handed. Ractor::TVar.allocate
    # gave a TVar with a NULL slot, and the thread local holding the transaction
    # log is writable from Ruby, so either one segfaulted.
    assert_raise(TypeError) { Ractor::TVar.allocate }

    t = Thread.new do
      Thread.current[:__ractor_tvar_tls__] = Object.new
      assert_raise(TypeError) { Ractor::TVar.new(1).value }
    end
    t.join
  end

  test "a TVar reachable only from a transaction in flight survives a GC" do
    # The transaction log holds a raw pointer to the TVar's slot and the TVar
    # itself to keep it alive. The TVar went unmarked, so a GC here freed the
    # slot and the commit locked a mutex that was no longer there.
    50.times do
      Ractor.atomically do
        tv = Ractor::TVar.new(1)
        tv.value = 2
        tv = nil
        GC.start(full_mark: true, immediate_sweep: true)
      end
    end
    assert_true true, "did not crash"
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
    # Not left to a race: contention makes a retry likely but never certain, and
    # on a single CPU the transactions just serialize (this assertion used to
    # fail every run there). Instead the conflict is staged: the transaction
    # reads, then pauses while another commit lands, so its own commit must
    # retry. Deterministic on any core count.
    tv = Ractor::TVar.new(0)
    runs = 0
    read = Queue.new
    resume = Queue.new
    t = Thread.new do
      Ractor.atomically do
        runs += 1
        v = tv.value
        if runs == 1
          read << :read      # first run only: let the other commit in between
          resume.pop
        end
        tv.value = v + 1
      end
    end
    read.pop
    Ractor.atomically { tv.value += 10 }   # invalidates what the block read
    resume << :go
    t.join
    assert_operator runs, :>, 1, "the block ran again after losing the race"
    assert_equal 11, tv.value, "and the losing run's write was discarded"
  end

  test "the transaction errors exist" do
    assert_operator Ractor::TransactionError, :<, RuntimeError
    assert_operator Ractor::RetryTransaction, :<, Exception
  end
end
