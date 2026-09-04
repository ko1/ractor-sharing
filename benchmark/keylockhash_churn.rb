# frozen_string_literal: true
#
# KeyLockHash's append-only entry arena makes insert/delete churn a deliberate
# time/space tradeoff.  Measure both sides of it rather than reporting only
# steady-state operation latency.
#
#   ruby -Ilib benchmark/keylockhash_churn.rb
#   KEY_KINDS=string PER=100000 BENCH_CS=1,4,8 REPS=3 \
#     ruby -Ilib benchmark/keylockhash_churn.rb

require_relative "lib/bench"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
Warning[:experimental] = false
require "ractor/sharing"
require "objspace"

PER = Integer(ENV.fetch("PER", "50000"))
CS = ENV.fetch("BENCH_CS", "1,2,4,8").split(",").map { Integer(_1) }
REPS = Integer(ENV.fetch("REPS", "3"))
KEY_KINDS = ENV.fetch("KEY_KINDS", "integer,string").split(",").map { _1.to_sym }
abort "KEY_KINDS must contain only integer,string" unless (KEY_KINDS - %i[integer string]).empty?

Result = Data.define(:measure, :retained_bytes, :retained_string_bytes)

def one_run(kind, workload, key_kind, concurrency, per)
  map = kind == :keylockhash ? Ractor::KeyLockHash.new : Ractor::LockHash.new
  ready = Ractor::Port.new
  ractors = concurrency.times.map do |id|
    Ractor.new(map, ready, kind, workload, key_kind, id, per) do |x, gate, implementation, work, keys, worker_id, n|
      gate << :ready
      Ractor.receive
      base = worker_id * n
      case [implementation, work]
      when [:keylockhash, :insert]
        n.times do |i|
          number = base + i
          key = keys == :integer ? number : "key-#{number}".freeze
          x[key] = number
        end
      when [:keylockhash, :churn]
        n.times do |i|
          number = base + i
          key = keys == :integer ? number : "key-#{number}".freeze
          x[key] = number
          x.delete(key)
        end
      when [:lockhash, :insert]
        n.times do |i|
          number = base + i
          key = keys == :integer ? number : "key-#{number}".freeze
          x.synchronize { |h| h[key] = number }
        end
      when [:lockhash, :churn]
        n.times do |i|
          number = base + i
          key = keys == :integer ? number : "key-#{number}".freeze
          x.synchronize { |h| h[key] = number; h.delete(key) }
        end
      end
      :ok
    end
  end
  concurrency.times { ready.receive }
  GC.start(full_mark: true, immediate_sweep: true)
  strings_before = ObjectSpace.memsize_of_all(String)

  measure = bmeasure(concurrency * per) do
    ractors.each { |r| r.send(:go) }
    ractors.each { |r| abort "worker failed" unless r.value == :ok }
  end
  expected = workload == :insert ? concurrency * per : 0
  abort "#{kind}/#{workload}: #{map.keys.size} keys, expected #{expected}" unless map.keys.size == expected
  GC.start(full_mark: true, immediate_sweep: true)
  Result.new(measure, ObjectSpace.memsize_of(map),
             ObjectSpace.memsize_of_all(String) - strings_before)
ensure
  ractors&.each { |r| r.close rescue nil }
end

def median_result(results)
  results.sort_by { |result| result.measure.per_op_us }[results.length / 2]
end

puts RUBY_DESCRIPTION
puts "unique keys, n=#{PER} per Ractor, median of #{REPS} runs"
puts "rate is completed keys/s; retained table/String bytes are measured after full GC"

KEY_KINDS.each do |key_kind|
  CS.each do |concurrency|
    puts
    puts "#{key_kind} keys, C=#{concurrency}"
    [[:keylockhash, :insert], [:lockhash, :insert],
     [:keylockhash, :churn], [:lockhash, :churn]].each do |kind, workload|
      result = median_result(Array.new(REPS) do
        one_run(kind, workload, key_kind, concurrency, PER)
      end)
      measure = result.measure
      label = "#{kind == :keylockhash ? "KeyLockHash" : "LockHash"} #{workload}"
      puts format("%-20s %10.0f/s %7.3f us  rss %+7d KB  gc %4dms/%-3d  table %9d B  strings %+9d B",
                  label, measure.per_sec, measure.per_op_us, measure.rss_delta_kb,
                  measure.gc_ms, measure.gc_count, result.retained_bytes,
                  result.retained_string_bytes)
    end
  end
end
