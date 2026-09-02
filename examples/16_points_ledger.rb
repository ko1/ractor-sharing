# frozen_string_literal: true
#
# The LockHash case in its purest form: a points ledger where every transfer
# touches TWO keys -- debit one account, credit another -- and accounts come
# into existence at first credit. Both sides of a transfer, account creation
# included, happen under one synchronize, so the auditor's invariant is brutal
# and simple: in every snapshot ever taken, the points sum to exactly what was
# minted, and no balance is negative.
#
# Neither neighbour can do this: KeyLockHash locks one key at a time, and a
# TVar per account needs the accounts known in advance.
#
#   ruby -Ilib examples/16_points_ledger.rb
Warning[:experimental] = false
require "ractor/sharing"

MINTED = 1_000
ledger = Ractor::LockHash.new(bank: MINTED)

workers = 4.times.map do |i|
  Ractor.new(ledger, i) do |led, id|
    rng = Random.new(7 + id)
    moved = 0
    200.times do
      pool = [:bank, :pot, "#{id}-a", "#{id}-b", "#{id}-c"]
      from, to = pool.sample(2, random: rng)
      amount = rng.rand(1..5)
      led.synchronize do |h|
        balance = h[from] || 0
        give = [balance, amount].min
        next if give.zero?

        h[from] = balance - give
        h[to] = (h[to] || 0) + give   # first credit CREATES the account, same section
        moved += give
      end
    end
    moved
  end
end

auditor = Ractor.new(ledger, MINTED) do |led, minted|
  300.times.count do
    snap = led.to_h
    sum = snap.values.sum
    abort "points minted or burned: #{sum}" unless sum == minted
    abort "negative balance: #{snap}" if snap.values.any?(&:negative?)
    true
  end
end

audits = auditor.value
moved = workers.sum(&:value)
books = ledger.to_h
abort "final sum off: #{books}" unless books.values.sum == MINTED
abort "no accounts were created" unless books.size > 2
puts "ok: #{moved} points moved across #{books.size} accounts " \
     "(#{books.size - 2} created mid-flight); #{audits} audits, every one summed to #{MINTED}"
