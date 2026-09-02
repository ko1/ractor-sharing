# frozen_string_literal: true
#
# An LRU cache is a Hash plus an eviction order, mutated on every hit -- state
# you have no intention of freezing. Give it a Ractor of its own: callers see
# ordinary methods, the owner runs them one at a time, and the object graph
# never leaves home.
#
#   ruby -Ilib examples/08_lru_cache.rb
Warning[:experimental] = false
require "ractor/sharing"

class LRUCache < Ractor::ActiveObject
  def initialize(capacity)
    @capacity = capacity
    @h = {}          # key => value
    @order = []      # least recently used first
    @hits = @misses = 0
  end

  sync def get(key)
    if @h.key?(key)
      @hits += 1
      @order.delete(key)
      @order << key
      @h[key]
    else
      @misses += 1
      nil
    end
  end

  sync def put(key, value)
    @order.delete(key)
    @order << key
    @h[key] = value
    @h.delete(@order.shift) while @h.size > @capacity
    value
  end

  sync def stats = { size: @h.size, hits: @hits, misses: @misses }.freeze
end

cache = LRUCache.new(8)

rs = 4.times.map do
  Ractor.new(cache) do |c|
    200.times do |i|
      key = "item-#{(i * 7) % 20}"
      c.get(key) or c.put(key, "value of #{key}")
    end
    :ok
  end
end
rs.each(&:join)

s = cache.stats
abort "capacity breached: #{s}" if s[:size] > 8
abort "nothing happened: #{s}" unless s[:hits] + s[:misses] == 800
puts "ok: #{s[:size]}/8 slots, #{s[:hits]} hits, #{s[:misses]} misses across 4 Ractors"
