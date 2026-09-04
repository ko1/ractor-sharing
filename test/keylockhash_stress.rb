# frozen_string_literal: true

# Opt-in only: this filename deliberately does not end in _test.rb.
#
#   bundle exec rake stress:keylockhash
#   KLH_STRESS_ROUNDS=10000 KLH_STRESS_WORKERS=8 \
#     KLH_STRESS_SEEDS=2,3,5,7 bundle exec rake stress:keylockhash

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
Warning[:experimental] = false
require "ractor/sharing"
require_relative "support/keylockhash_stress"

seeds = ENV.fetch("KLH_STRESS_SEEDS", "1,17,104729").split(",").map { Integer(_1) }
workers = Integer(ENV.fetch("KLH_STRESS_WORKERS", "6"))
rounds = Integer(ENV.fetch("KLH_STRESS_ROUNDS", "2000"))
gc_rounds = Integer(ENV.fetch("KLH_STRESS_GC_ROUNDS", "80"))
compact = ENV.fetch("KLH_STRESS_COMPACT", "1") != "0"
timeout = Integer(ENV.fetch("KLH_STRESS_TIMEOUT", "60"))
raise ArgumentError, "KLH_STRESS_SEEDS must not be empty" if seeds.empty?

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
seeds.each do |seed|
  result = KeyLockHashStress.run(seed: seed, workers: workers, rounds: rounds,
                                 gc_rounds: gc_rounds, compact: compact,
                                 timeout: timeout)
  warn "seed=#{seed} operations=#{result[:operations]} live=#{result[:live_keys]} " \
       "deleted=#{result[:deleted_keys]} rollbacks=#{result[:rollback_successes]}"
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
warn format("KeyLockHash stress passed: %d seeds in %.3fs", seeds.length, elapsed)
