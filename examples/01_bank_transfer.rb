# frozen_string_literal: true
#
# The classic STM example, because nothing shows "all or none" better: money
# moves between accounts, and no observer ever sees it in neither.
#
#   ruby -Ilib examples/01_bank_transfer.rb
Warning[:experimental] = false
require "ractor/sharing"

accounts = { alice: Ractor::TVar.new(300), bob: Ractor::TVar.new(300), carol: Ractor::TVar.new(300) }
Ractor.make_shareable(accounts)
TOTAL = 900

# Three tellers shuffle money along a ring. Each transfer is one transaction:
# both balances change together or not at all.
tellers = accounts.keys.zip(accounts.keys.rotate).map do |from, to|
  Ractor.new(accounts[from], accounts[to]) do |a, b|
    500.times do
      Ractor.atomically do
        amount = a.value >= 5 ? 5 : a.value
        a.value -= amount
        b.value += amount
      end
    end
    :ok
  end
end

# The auditor reads all three inside one transaction, so it sees a consistent
# snapshot: the total must be exact in every single read, mid-shuffle included.
auditor = Ractor.new(accounts) do |acc|
  1_000.times.count do
    total = Ractor.atomically { acc.each_value.sum(&:value) }
    abort "audit failed: saw #{total}" unless total == TOTAL
    true
  end
end

audits = auditor.value
tellers.each(&:join)
final = accounts.transform_values(&:value)
abort "money leaked: #{final}" unless final.values.sum == TOTAL
puts "ok: #{audits} audits mid-shuffle, every one saw exactly #{TOTAL}; final #{final}"
