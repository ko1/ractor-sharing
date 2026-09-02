# frozen_string_literal: true
#
# Fan out, then gather: ask several slow services for quotes as futures, do
# other work, and only then sit down to wait. Each future is a ticket for an
# answer that is being computed while you are not looking.
#
#   ruby -Ilib examples/10_price_quotes.rb
Warning[:experimental] = false
require "ractor/sharing"

class PriceService < Ractor::ActiveObject
  def initialize(vendor, base)
    @vendor = vendor
    @base = base
  end

  future def quote(item)
    sleep 0.05  # the network, allegedly
    { vendor: @vendor, item: item, price: @base + item.sum % 17 }.freeze
  end
end

services = { "acme" => 100, "moma" => 90, "zenith" => 95 }.map { |v, base| PriceService.new(v, base) }

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
futures = services.map { |s| s.quote("garden gnome") }   # all three are working now
elapsed_to_fire = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

quotes = futures.map(&:value)                            # now we wait
elapsed_total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

best = quotes.min_by { |q| q[:price] }
abort "missing quotes: #{quotes}" unless quotes.size == 3 && quotes.all? { |q| q[:price].positive? }
abort "firing the futures blocked" if elapsed_to_fire > 0.04
puts format("ok: 3 quotes in %.0f ms (three 50 ms sleeps, overlapped); best: %s at %d",
            elapsed_total * 1000, best[:vendor], best[:price])
