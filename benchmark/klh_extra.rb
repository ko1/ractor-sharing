# Two KeyLockHash properties the record sweep does not isolate:
#   (1) store_if_absent on one hot key -- a hit is a lock-free read -- against a
#       Mutex+Hash memoize (what you would otherwise write).
#   (2) writes over one shared map, a key per Ractor: per-key locks scale where
#       LockHash's single table lock does not.
require "ractor/sharing"
Warning[:experimental] = false
PER = Integer(ENV["PER"] || 1_000_000)
CS  = (ENV["CS"] || "1,2,4,8,16").split(",").map(&:to_i)

def bench(c, per)
  gate = Ractor::LockVar.new(false)
  rs = yield(gate, c)
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  gate.update { true }
  rs.map(&:value)
  dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  dt * 1e9 / (per.to_f * c)
end

puts RUBY_DESCRIPTION
puts "PER=#{PER} per ractor, ns per op (all Ractors)\n\n"

# (1) store_if_absent hot key: KLH (lock-free hit) vs Mutex+Hash
klh = Ractor::KeyLockHash.new
klh.store_if_absent(:k) { 41 }                 # prime the one hot key
sia = Ractor.shareable_proc { |o| o.store_if_absent(:k) { 41 } }
puts "store_if_absent hot key (one shared key, all read it):"
printf "%-28s" + "  C=%d"*CS.size + "\n", "", *CS
r1 = CS.map { |c| bench(c, PER) { |g, cc| cc.times.map { Ractor.new(klh, g, sia) { |o,gg,f| nil until gg.value; PER.times { f.call(o) }; nil } } } }
printf "%-28s" + " %5.0f"*CS.size + "\n", "KeyLockHash#store_if_absent", *r1
# baseline: a locked hash memoize -- take the lock, read-or-compute the one key
lh0 = Ractor::LockHash.new(k: 41)
lhm = Ractor.shareable_proc { |o| o.synchronize { o[:k] || (o[:k] = 41) } }
r2 = CS.map { |c| bench(c, PER) { |g, cc| cc.times.map { Ractor.new(lh0, g, lhm) { |o,gg,f| nil until gg.value; PER.times { f.call(o) }; nil } } } }
printf "%-28s" + " %5.0f"*CS.size + "\n\n", "LockHash memoize (under lock)", *r2

# (2) one shared map, a key per Ractor: KLH vs LockHash
puts "one shared map, a key per Ractor (writes):"
printf "%-28s" + "  C=%d"*CS.size + "\n", "", *CS
klh2 = Ractor::KeyLockHash.new
klhw = Ractor.shareable_proc { |o, k| o.update(k) { |v| (v || 0) + 1 } }
r3 = CS.map { |c| bench(c, PER) { |g, cc| cc.times.map { |i| Ractor.new(klh2, g, klhw, i) { |o,gg,f,k| nil until gg.value; PER.times { f.call(o, k) }; nil } } } }
printf "%-28s" + " %5.0f"*CS.size + "\n", "KeyLockHash#update", *r3
lh = Ractor::LockHash.new
lhw = Ractor.shareable_proc { |o, k| o.synchronize { o[k] = (o[k] || 0) + 1 } }
r4 = CS.map { |c| bench(c, PER) { |g, cc| cc.times.map { |i| Ractor.new(lh, g, lhw, i) { |o,gg,f,k| nil until gg.value; PER.times { f.call(o, k) }; nil } } } }
printf "%-28s" + " %5.0f"*CS.size + "\n", "LockHash#synchronize", *r4
