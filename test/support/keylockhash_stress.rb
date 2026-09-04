# frozen_string_literal: true

require "timeout"

module KeyLockHashStress
  module_function

  CACHE_SLOTS = 32

  class CollisionKey
    attr_reader :id

    def initialize(id)
      @id = id
      freeze
    end

    def hash = 1
    def eql?(other) = other.is_a?(CollisionKey) && other.id == id
  end

  def run(seed:, workers:, rounds:, gc_rounds:, compact:, timeout:)
    raise ArgumentError, "workers must be positive" unless workers.positive?
    raise ArgumentError, "rounds must be at least #{CACHE_SLOTS}" if rounds < CACHE_SLOTS
    raise ArgumentError, "gc_rounds must not be negative" if gc_rounds.negative?
    raise ArgumentError, "timeout must be positive" unless timeout.positive?

    map = Ractor::KeyLockHash.new(anchor: :stable, anchor2: :also_stable)
    ready = Ractor::Port.new

    worker_ractors = workers.times.map do |id|
      Ractor.new(map, ready, seed, id, rounds) do |x, barrier, base_seed, worker_id, n|
        random = Random.new(base_seed + worker_id)
        own_key = "own-#{worker_id}".freeze
        kept = []
        removed = []
        successful_rollbacks = 0

        start = Ractor::Port.new
        barrier << start
        start.receive
        n.times do |i|
          x.increment(:shared)
          x.update(own_key) { |old| Thread.pass if random.rand(8).zero?; (old || 0) + 1 }

          should_raise = ((i + worker_id) % 23).zero?
          begin
            x.update(:rollback) do |old|
              Thread.pass if random.rand(4).zero?
              raise "intentional" if should_raise
              (old || 0) + 1
            end
            raise "rollback did not raise" if should_raise
            successful_rollbacks += 1
          rescue RuntimeError => error
            raise unless should_raise && error.message == "intentional"
          end

          slot = i % KeyLockHashStress::CACHE_SLOTS
          cached = x.store_if_absent("cache-#{slot}".freeze) { [slot, worker_id] }
          raise "invalid cache value: #{cached.inspect}" unless cached[0] == slot

          churn_key = (worker_id + 1) * 10_000_000 + i
          x[churn_key] = i
          raise "write was not visible" unless x[churn_key] == i
          if random.rand(3).zero?
            raise "delete returned the wrong value" unless x.delete(churn_key) == i
            removed << churn_key
          else
            kept << [churn_key, i]
          end
        end
        [kept, removed, successful_rollbacks]
      end
    end

    reader_rounds = [rounds / 5, 20].max
    reader_ractors = 2.times.map do
      Ractor.new(map, ready, reader_rounds) do |x, barrier, n|
        start = Ractor::Port.new
        barrier << start
        start.receive
        n.times do |i|
          raise "anchor disappeared" unless x[:anchor] == :stable
          raise "fetch observed a wrong value" unless x.fetch(:anchor2) == :also_stable
          next unless (i % 17).zero?

          snapshot = x.to_h
          raise "snapshot lost anchor" unless snapshot[:anchor] == :stable
          keys = x.keys
          raise "keys contained a duplicate" unless keys.length == keys.uniq.length
        end
        :reader_ok
      end
    end

    gc_ractor = Ractor.new(ready, gc_rounds, compact) do |barrier, n, compact_gc|
      start = Ractor::Port.new
      barrier << start
      start.receive
      n.times do |i|
        GC.start(full_mark: (i % 7).zero?, immediate_sweep: true)
        GC.compact if compact_gc && (i % 13).zero?
        Thread.pass
      end
      :gc_ok
    end

    all_ractors = worker_ractors + reader_ractors + [gc_ractor]
    starts = all_ractors.length.times.map { ready.receive }
    starts.each { |start| start << true }

    worker_results = nil
    Timeout.timeout(timeout) do
      worker_results = worker_ractors.map(&:value)
      reader_ractors.each { |r| check(r.value == :reader_ok, "reader did not finish") }
      check(gc_ractor.value == :gc_ok, "GC hammer did not finish")
    end

    kept = worker_results.flat_map { |result| result[0] }
    removed = worker_results.flat_map { |result| result[1] }
    rollback_successes = worker_results.sum { |result| result[2] }

    check(map[:shared] == workers * rounds,
          "shared count: expected #{workers * rounds}, got #{map[:shared].inspect}")
    workers.times do |id|
      check(map["own-#{id}"] == rounds,
            "worker #{id} count: expected #{rounds}, got #{map["own-#{id}"].inspect}")
    end
    check(map[:rollback] == rollback_successes,
          "rollback count: expected #{rollback_successes}, got #{map[:rollback].inspect}")

    CACHE_SLOTS.times do |slot|
      cached = map["cache-#{slot}"]
      check(cached.is_a?(Array) && cached[0] == slot && (0...workers).cover?(cached[1]),
            "cache slot #{slot} is invalid: #{cached.inspect}")
    end
    kept.each { |key, value| check(map[key] == value, "kept key #{key} changed") }
    removed.each { |key| check(map[key].nil?, "deleted key #{key} reappeared") }

    snapshot = map.to_h
    expected_size = 4 + workers + CACHE_SLOTS + kept.length
    check(snapshot.size == expected_size,
          "snapshot size: expected #{expected_size}, got #{snapshot.size}")
    check(map.keys.length == expected_size,
          "keys size: expected #{expected_size}, got #{map.keys.length}")

    run_claim_resize(workers: workers, entries_per_worker: [rounds, 128].max,
                     gc_rounds: gc_rounds, compact: compact, timeout: timeout)
    run_collision_keys(workers: workers,
                       rounds: (rounds / 4).clamp(100, 2_000),
                       timeout: timeout)
    run_numeric_boundary(workers: workers,
                         rounds: (rounds / 10).clamp(64, 512),
                         timeout: timeout)
    run_store_if_absent_waves(workers: workers,
                              waves: (rounds / 200).clamp(5, 32),
                              timeout: timeout)

    { operations: workers * rounds, live_keys: expected_size,
      deleted_keys: removed.length, rollback_successes: rollback_successes }
  ensure
    all_ractors&.each { |r| r.close rescue nil }
  end

  def run_claim_resize(workers:, entries_per_worker:, gc_rounds:, compact:, timeout:)
    map = Ractor::KeyLockHash.new(held: 0)
    entered = Ractor::Port.new
    release = nil
    owner = Ractor.new(map, entered) do |x, ready|
      x.update(:held) do |old|
        finish = Ractor::Port.new
        ready << [:claimed, finish]
        finish.receive
        old + 1
      end
    end

    Timeout.timeout(timeout) do
      state, release = entered.receive
      check(state == :claimed, "claim was not entered")
    end

    waiters = workers.times.map do
      Ractor.new(map) { |x| x.update(:held) { |old| Thread.pass; old + 1 } }
    end
    resizers = workers.times.map do |id|
      Ractor.new(map, id, entries_per_worker) do |x, worker_id, n|
        n.times do |i|
          key = 100_000_000 + worker_id * n + i
          x[key] = key
        end
        :resize_ok
      end
    end
    reader = Ractor.new(map, entries_per_worker) do |x, n|
      n.times do
        raise "uncommitted claim became visible" unless x[:held] == 0
        Thread.pass
      end
      :reader_ok
    end
    gc_ractor = Ractor.new(gc_rounds, compact) do |n, compact_gc|
      n.times do |i|
        GC.start(full_mark: true, immediate_sweep: true)
        GC.compact if compact_gc && (i % 5).zero?
      end
      :gc_ok
    end

    all_ractors = [owner] + waiters + resizers + [reader, gc_ractor]
    Timeout.timeout(timeout) do
      resizers.each { |r| check(r.value == :resize_ok, "resize writer failed") }
      check(reader.value == :reader_ok, "claim reader failed")
      check(gc_ractor.value == :gc_ok, "resize GC hammer failed")
      release << true
      check(owner.value == 1, "claim owner committed the wrong value")
      waiters.each(&:value)
    end

    check(map[:held] == workers + 1,
          "waiter count: expected #{workers + 1}, got #{map[:held].inspect}")
    expected_size = 1 + workers * entries_per_worker
    check(map.keys.size == expected_size,
          "resize keys: expected #{expected_size}, got #{map.keys.size}")
  ensure
    release << true rescue nil if release
    all_ractors&.each { |r| r.close rescue nil }
  end

  def run_collision_keys(workers:, rounds:, timeout:)
    key_count = 64
    keys = Ractor.make_shareable(Array.new(key_count) { |i| CollisionKey.new(i) })
    map = Ractor::KeyLockHash.new
    ready = Ractor::Port.new
    ractors = workers.times.map do |id|
      Ractor.new(map, keys, ready, id, rounds, key_count) do |x, colliding, barrier, worker_id, n, count|
        local_counts = Array.new(count, 0)
        start = Ractor::Port.new
        barrier << start
        start.receive

        n.times do |i|
          index = (i * 17 + worker_id * 13) % count
          x.update(colliding[index]) { |old| Thread.pass if (i % 11).zero?; (old || 0) + 1 }
          local_counts[index] += 1

          # Exercise #hash/#eql? with a different object representing the
          # same key while every key occupies the same probe cluster.
          if (i % 19).zero?
            probe = Ractor.make_shareable(KeyLockHashStress::CollisionKey.new(index))
            raise "equivalent collision key was not found" unless x[probe]&.positive?
          end

          x.update(String.new("equivalent-string").freeze) { |old| (old || 0) + 1 }
        end
        local_counts
      end
    end

    starts = ractors.length.times.map { ready.receive }
    starts.each { |start| start << true }
    counts = nil
    Timeout.timeout(timeout) { counts = ractors.map(&:value) }

    key_count.times do |index|
      expected = counts.sum { |local| local[index] }
      check(map[keys[index]] == expected,
            "collision key #{index}: expected #{expected}, got #{map[keys[index]].inspect}")
      equivalent = Ractor.make_shareable(CollisionKey.new(index))
      check(map[equivalent] == expected, "equivalent collision key #{index} differed")
    end
    check(map["equivalent-string"] == workers * rounds,
          "equivalent strings lost updates")
    check(map.keys.size == key_count + 1, "collision table has duplicate logical keys")
  ensure
    ractors&.each { |r| r.close rescue nil }
  end

  def run_numeric_boundary(workers:, rounds:, timeout:)
    total = workers * rounds
    fixnum_max = 2**(0.size * 8 - 2) - 1
    initial = fixnum_max - total / 2
    map = Ractor::KeyLockHash.new(edge: initial)

    incrementers = workers.times.map do
      Ractor.new(map, rounds) do |x, n|
        n.times { |i| x.increment(:edge); Thread.pass if (i % 17).zero? }
      end
    end
    Timeout.timeout(timeout) { incrementers.each(&:value) }
    check(map[:edge] == initial + total,
          "Fixnum/Bignum crossing lost increments: #{map[:edge].inspect}")

    decrementers = workers.times.map do
      Ractor.new(map, rounds) do |x, n|
        n.times { |i| x.increment(:edge, -1); Thread.pass if (i % 13).zero? }
      end
    end
    Timeout.timeout(timeout) { decrementers.each(&:value) }
    check(map[:edge] == initial,
          "Bignum/Fixnum crossing lost decrements: #{map[:edge].inspect}")
  ensure
    incrementers&.each { |r| r.close rescue nil }
    decrementers&.each { |r| r.close rescue nil }
  end

  def run_store_if_absent_waves(workers:, waves:, timeout:)
    map = Ractor::KeyLockHash.new

    waves.times do |wave|
      map.delete(:memo)
      ractors = workers.times.map do |id|
        Ractor.new(map, wave, id) do |x, generation, worker_id|
          computed = false
          value = x.store_if_absent(:memo) do
            computed = true
            3.times { Thread.pass }
            [generation, worker_id]
          end
          [value, computed]
        end
      end
      results = nil
      Timeout.timeout(timeout) { results = ractors.map(&:value) }
      computed = results.count { |result| result[1] }
      check(computed == 1,
            "store_if_absent wave #{wave} computed #{computed} times")
      values = results.map(&:first)
      check(values.uniq.size == 1 && values.first[0] == wave,
            "store_if_absent wave #{wave} returned inconsistent values")
    ensure
      ractors&.each { |r| r.close rescue nil }
    end

    map.delete(:memo)
    nil_ractors = workers.times.map do
      Ractor.new(map) do |x|
        computed = false
        value = x.store_if_absent(:memo) { computed = true; Thread.pass; nil }
        [value, computed]
      end
    end
    nil_results = nil
    Timeout.timeout(timeout) { nil_results = nil_ractors.map(&:value) }
    check(nil_results.all? { |value, computed| value.nil? && computed },
          "nil store_if_absent was cached or skipped a computation")
    check(!map.key?(:memo), "nil store_if_absent left a live entry")
  ensure
    nil_ractors&.each { |r| r.close rescue nil }
  end

  def check(condition, message)
    raise message unless condition
  end
end
