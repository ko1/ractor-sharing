# frozen_string_literal: true
#
# 1 つのオブジェクトを C 個の caller Ractor が同時に叩く。owner Ractor が
# 直列化点なので、ここで見たいのは「1 オブジェクトのスループットは並行度で
# 伸びるのか、それとも owner で頭打ちになるのか」。
#
#   CALLERS=16 ruby benchmark/contention.rb
#
# 掃引点は nproc の前後を跨ぐこと（1/2/8/16/32/64）。
Warning[:experimental] = false
require_relative "lib/bench"
require_relative "../../lib/ractor/active_object"

CALLERS = bconc(Integer(ENV.fetch("CALLERS", 8)))
PER     = bscale(Integer(ENV.fetch("PER", 5_000)))
POLICY  = ENV.fetch("POLICY", "sync")   # sync | async

class Shared < Ractor::ActiveObject
  def initialize = @n = 0
  sync  def bump   = @n += 1
  async def bump_a = @n += 1
  sync  def get    = @n
end

puts RUBY_DESCRIPTION
obj = Shared.new
obj.bump   # warm

gate = Ractor::Port.new
done = Ractor::Port.new
callers = CALLERS.times.map do
  Ractor.new(obj, gate, done, PER, POLICY) do |o, g, d, n, policy|
    g << :ready
    Ractor.receive
    if policy == "async"
      n.times { o.bump_a }
      o.get              # barrier: キューを空にしてから終わる
    else
      n.times { o.bump }
    end
    d << :done
  end
end
CALLERS.times { gate.receive }

total = CALLERS * PER
m = bmeasure(total) do
  callers.each { _1.send(:go) }
  CALLERS.times { done.receive }
end
callers.each { _1.value rescue nil }

puts brate(format("callers=%-3d %s", CALLERS, POLICY), m,
           extra: format("count=%d", obj.get))
