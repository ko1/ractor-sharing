# frozen_string_literal: true
#
# Two memoizations of the same subject, primes, because "memoize" means two
# different shapes here and the family has a different tool for each.
#
#   is_prime?(n)   independent keys: a value per n, computed once. That is
#                  get-or-create -- KeyLockHash#update, the block holding the
#                  key's lock so a dog-pile of callers on one n trial-divides
#                  it once and the rest read the answer.
#
#   nth_prime(i)   ONE growing sequence: a sieve that only ever extends. That
#                  is single mutable state -- an ActiveObject owning the sieve,
#                  extending it under demand, never recomputing a prime it found.
#
#   ruby -Ilib examples/19_prime_memo.rb
Warning[:experimental] = false
require "ractor/sharing"

def trial_divide(n)                       # the "expensive" computation
  return false if n < 2
  2.upto(Integer.sqrt(n)) { |d| return false if n % d == 0 }
  true
end

# --- is_prime?: independent keys, computed once each -------------------------
# The value stored is [prime?, computed_by] so a reader can tell, after the
# fact, which Ractor actually ran the trial division -- exactly one did, even
# when eight pile onto the same n. (Counting inside the block is not an option:
# it holds this key's lock, and touching a second lock there is NestedLockError
# by design.)
CACHE = Ractor::KeyLockHash.new

def is_prime?(n, who)
  CACHE.update(n) {|v| v.nil? ? [trial_divide(n), who] : v }.first
end

# --- nth_prime: one growing sieve, owned ------------------------------------
class PrimeSequence < Ractor::ActiveObject
  def initialize = (@primes = [2, 3]; @extends = 0)

  sync def nth(i)
    grow_to(i + 1) if i >= @primes.size
    @primes[i]
  end

  sync def extends = @extends              # how many times we actually computed

  private

  def grow_to(count)
    @extends += 1
    cand = @primes.last + 2
    while @primes.size < count
      cand += 2 while @primes.any? { |p| p * p <= cand && cand % p == 0 }
      @primes << cand
      cand += 2
    end
  end
end
SEQ = PrimeSequence.new

# --- exercise both from many Ractors ----------------------------------------
KNOWN = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47].freeze

cache_workers = 8.times.map do |w|
  Ractor.new(w) do |who|
    200.times.count { |i| is_prime?(2 + i % 60, who) }   # 8 Ractors pile on 60 shared n
  end
end
cache_workers.each(&:join)

seq_workers = 8.times.map do
  Ractor.new(SEQ) do |seq|
    (0...KNOWN.size).map { |i| seq.nth(i) }          # all race to read the same prefix
  end
end
feeds = seq_workers.map(&:value)

# checks
distinct_n = 60                                       # is_prime? saw n in 2..61
computers = CACHE.to_h.values.map(&:last)             # who computed each n
abort "computed #{computers.size} values, expected #{distinct_n}" unless computers.size == distinct_n
[2, 17, 41, 60].each { |n| abort "is_prime?(#{n}) wrong" unless is_prime?(n, :check) == trial_divide(n) }
abort "a reader saw a wrong sequence" unless feeds.all? { |f| f == KNOWN }
abort "sieve recomputed a known prime" unless SEQ.extends <= KNOWN.size

puts "ok: is_prime? trial-divided each of #{distinct_n} values exactly once for 1600 " \
     "calls across 8 Ractors; nth_prime served the same #{KNOWN.size}-prime prefix to 8 " \
     "Ractors, sieve grown #{SEQ.extends}x"
