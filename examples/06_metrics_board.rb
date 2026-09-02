# frozen_string_literal: true
#
# Request metrics: a per-endpoint record AND a global total that must agree.
# Two keys changing together is exactly what LockHash's synchronize gives you,
# and to_h is a snapshot taken under the same lock -- so every report balances,
# even taken mid-flight from another Ractor.
#
#   ruby -Ilib examples/06_metrics_board.rb
Warning[:experimental] = false
require "ractor/sharing"

board = Ractor::LockHash.new(total: 0)
ENDPOINTS = %w[/home /search /cart].freeze

workers = 4.times.map do
  Ractor.new(board) do |b|
    300.times do |i|
      ep = ENDPOINTS[i % ENDPOINTS.size]
      ms = 5 + i % 20
      b.synchronize do |h|
        rec = h[ep] || { count: 0, total_ms: 0, worst_ms: 0 }.freeze
        h[ep] = { count: rec[:count] + 1, total_ms: rec[:total_ms] + ms,
                  worst_ms: [rec[:worst_ms], ms].max }.freeze
        h[:total] = h[:total] + 1   # the cross-key part: total moves with the record
      end
    end
    :ok
  end
end

# The reporter never catches the books unbalanced: per-endpoint counts must sum
# to :total in every snapshot, because both changed under one synchronize.
reporter = Ractor.new(board) do |b|
  200.times.count do
    snap = b.to_h
    sum = snap.reject { |k, _| k == :total }.values.sum { |r| r[:count] }
    abort "unbalanced snapshot: #{sum} recorded but total says #{snap[:total]}" unless sum == snap[:total]
    true
  end
end

snapshots = reporter.value
workers.each(&:join)
final = board.to_h
abort "final books off" unless final[:total] == 1200
puts "ok: #{snapshots} mid-flight snapshots all balanced; " +
     final.reject { |k, _| k == :total }.map { |ep, r| "#{ep} avg #{r[:total_ms] / r[:count]}ms" }.join(", ")
