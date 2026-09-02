# frozen_string_literal: true
#
# A cache backend on KeyLockHash, and the reason it is one line: update(key)
# holds THAT KEY's lock while the block runs, so when eight workers miss the
# same key at once, exactly one computes and seven wait a few ms and read --
# the dog-pile (cache stampede) problem, solved by the locking shape itself.
# The price is the same shape: a slow compute blocks that key, and only that
# key. Real cache backends make exactly this trade.
#
#   ruby -Ilib examples/15_cache_backend.rb
Warning[:experimental] = false
require "ractor/sharing"

CACHE = Ractor::KeyLockHash.new

def fetch_fragment(key)
  computed = false
  html = CACHE.store_if_absent(key) do          # a hit never runs this block
    computed = true
    sleep 0.02                                 # an expensive render, allegedly
    "<div id=#{key}>rendered</div>"
  end
  [html, computed]
end

workers = 8.times.map do |i|
  Ractor.new(i) do |id|
    renders = 0
    hits = 0
    24.times do |n|
      key = "fragment-#{(n + id) % 6}"    # eight workers, six hot keys
      html, computed = fetch_fragment(key)
      abort "wrong fragment" unless html.include?(key)
      computed ? renders += 1 : hits += 1
    end
    [renders, hits]
  end
end

renders = workers.map(&:value)
total_renders = renders.sum(&:first)
total_hits = renders.sum(&:last)
abort "dog-pile: #{total_renders} renders for 6 keys" unless total_renders == 6
abort "misplaced arithmetic" unless total_renders + total_hits == 8 * 24

CACHE.delete("fragment-0")              # invalidation is just delete
_, recomputed = fetch_fragment("fragment-0")
abort "invalidation did not take" unless recomputed

puts "ok: 192 fetches, 6 renders (one per key, stampede absorbed), " \
     "#{total_hits} lock-protected hits; invalidate + refetch rendered once more"
