# frozen_string_literal: true
#
# Why LockVar exists when TVar is usually faster: a TVar transaction that loses
# a race RUNS ITS BLOCK AGAIN, so a side effect inside it repeats. A LockVar
# update waits its turn and runs the block exactly once. Here both race to be
# "the one who announces", and we count how often each block actually ran.
#
#   ruby -Ilib examples/05_exactly_once.rb
Warning[:experimental] = false
require "ractor/sharing"

N = 8
tv = Ractor::TVar.new(0)
lv = Ractor::LockVar.new(0)

# Each Ractor counts its own block executions in plain locals. (Not in another
# LockVar: touching one lock from inside another is refused, by design.)
rs = N.times.map do
  Ractor.new(tv, lv) do |t, l|
    tv_runs = lv_runs = 0
    250.times do
      Ractor.atomically { tv_runs += 1; t.value += 1 }  # side effect in a transaction: may rerun
      l.update { |v| lv_runs += 1; v + 1 }              # side effect under the lock: runs once
    end
    [tv_runs, lv_runs]
  end
end
counts = rs.map(&:value)
tv_runs = counts.sum(&:first)
lv_runs = counts.sum(&:last)

updates = N * 250
abort "TVar lost updates" unless tv.value == updates
abort "LockVar lost updates" unless lv.value == updates
abort "a LockVar block ran #{lv_runs} times for #{updates} updates" unless lv_runs == updates
extra = tv_runs - updates
puts "ok: #{updates} updates each. LockVar blocks ran exactly #{lv_runs}; " \
     "TVar blocks ran #{tv_runs} (#{extra} rerun#{'s' if extra != 1} -- keep side effects out of transactions)"
