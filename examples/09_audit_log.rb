# frozen_string_literal: true
#
# A fire-and-forget audit log: workers must not wait for the log to be written,
# so the method is async -- the call costs a send, not a round trip (about 5x
# cheaper on our bench machine). Reads are sync, because the answer is the point.
#
#   ruby -Ilib examples/09_audit_log.rb
Warning[:experimental] = false
require "ractor/sharing"

class AuditLog < Ractor::ActiveObject
  def initialize = @lines = []
  async def record(who, what) = @lines << "#{@lines.size}: #{who} #{what}"
  sync def size = @lines.size
  sync def tail(n) = @lines.last(n).dup
end

log = AuditLog.new

workers = %w[ann ben cho dee].map do |name|
  Ractor.new(log, name) do |l, me|
    150.times { |i| l.record(me, "step #{i}") }  # never waits
    l.size                                       # one sync call = my records landed
    :ok
  end
end
workers.each(&:join)

abort "records lost: #{log.size}" unless log.size == 600
abort "sequence torn" unless log.tail(600).each_with_index.all? { |line, i| line.start_with?("#{i}:") }
puts "ok: 600 records, strictly ordered by the owner; tail: #{log.tail(1).first.inspect}"
