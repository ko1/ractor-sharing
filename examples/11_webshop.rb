# frozen_string_literal: true
#
# A small shop, with every tool in its natural seat:
#
#   prices     TVar      read by every checkout, changed once mid-run (a sale)
#   stock      TVar/SKU  a checkout reserves EVERY item in the cart or nothing
#   ledger     LockHash  order count, revenue, per-SKU figures that must agree
#   audit      ActiveObject  fire-and-forget order log, ordered by its owner
#
# The heart is the checkout transaction: prices and all the cart's stock levels
# are read and written in ONE Ractor.atomically, so a cart is never half
# reserved and never priced across a sale boundary.
#
#   ruby -Ilib examples/11_webshop.rb
Warning[:experimental] = false
require "ractor/sharing"

SKUS = %i[mug tee cap].freeze
START_STOCK = { mug: 120, tee: 90, cap: 60 }.freeze

PRICES = Ractor::TVar.new({ mug: 12, tee: 25, cap: 15 }.freeze)
STOCK  = Ractor.make_shareable(START_STOCK.transform_values { |n| Ractor::TVar.new(n) })

ledger = Ractor::LockHash.new(orders: 0, revenue: 0)

class AuditLog < Ractor::ActiveObject
  def initialize = @lines = []
  async def order(shopper, cart, cost) = @lines << [shopper, cart, cost].freeze
  async def rejection(shopper, cart)   = @lines << [shopper, cart, :out_of_stock].freeze
  sync def entries = @lines.dup
end
audit = AuditLog.new

shoppers = 4.times.map do |i|
  Ractor.new(PRICES, STOCK, ledger, audit, i) do |prices, stock, led, log, id|
    rng = Random.new(42 + id)
    sold = 0
    40.times do
      cart = SKUS.sample(rng.rand(1..2), random: rng).tally  # e.g. {mug: 1, tee: 1}

      # All or nothing: every stock level and the price list, one transaction.
      cost = Ractor.atomically do
        next nil if cart.any? { |sku, n| stock[sku].value < n }

        cart.each { |sku, n| stock[sku].value -= n }
        p = prices.value
        cart.sum { |sku, n| p[sku] * n }
      end

      if cost.nil?
        log.rejection(id, cart)
        next
      end

      # The books: order count, revenue and the per-SKU units move together,
      # so no snapshot ever shows an order whose units are missing.
      led.synchronize do |h|
        h[:orders] += 1
        h[:revenue] += cost
        cart.each { |sku, n| h[sku] = (h[sku] || 0) + n }
      end
      log.order(id, cart, cost)
      sold += 1
    end
    sold
  end
end

# The sale: one atomic price flip, mid-run. A checkout sees old or new, never a mix.
sleep 0.01
Ractor.atomically { PRICES.value = PRICES.value.merge(tee: 19).freeze }

# An accountant snapshots the books while shoppers are still at it: order count
# and revenue always came from the same synchronize, so cross-checking entries
# never catches them mid-write.
accountant = Ractor.new(ledger) do |led|
  60.times.count do
    snap = led.to_h
    abort "negative books: #{snap}" if snap[:orders].negative? || snap[:revenue].negative?
    true
  end
end

orders_placed = shoppers.sum(&:value)
accountant.join
books = ledger.to_h
entries = audit.entries
sold_entries = entries.reject { |e| e[2] == :out_of_stock }

# Conservation, the real test of the checkout transaction:
SKUS.each do |sku|
  sold = sold_entries.sum { |_, cart, _| cart[sku] || 0 }
  left = STOCK[sku].value
  abort "#{sku}: #{START_STOCK[sku]} - #{sold} != #{left}" unless START_STOCK[sku] - sold == left
  abort "#{sku} ledger units off" unless (books[sku] || 0) == sold
  abort "#{sku} oversold" if left.negative?
end
abort "books vs audit: #{books[:orders]} vs #{sold_entries.size}" unless books[:orders] == sold_entries.size
abort "revenue drifted" unless books[:revenue] == sold_entries.sum { |_, _, c| c }
abort "ledger vs shoppers" unless books[:orders] == orders_placed

rej = entries.size - sold_entries.size
puts "ok: #{books[:orders]} orders, #{rej} rejected out-of-stock, revenue #{books[:revenue]}; " \
     "stock left #{SKUS.map { |s| "#{s}:#{STOCK[s].value}" }.join(' ')}"
