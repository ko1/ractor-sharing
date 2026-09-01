# frozen_string_literal: true
#
# N 個の独立したオブジェクト（= N 本の owner Ractor）を、それぞれ専属の caller が
# 叩く。contention.rb と対にして読む: あちらは 1 owner の頭打ち、こちらは owner を
# 増やせばコア数まで伸びるか。伸びなければ天井はスケジューラ側にある。
#
#   OBJECTS=16 ruby benchmark/objects.rb
Warning[:experimental] = false
require_relative "lib/bench"
require_relative "../../lib/ractor/active_object"

OBJECTS = bconc(Integer(ENV.fetch("OBJECTS", 8)))
PER     = bscale(Integer(ENV.fetch("PER", 5_000)))

class Cell < Ractor::ActiveObject
  def initialize = @n = 0
  sync def bump = @n += 1
end

puts RUBY_DESCRIPTION

# 生成そのものも値段のうち（1 オブジェクト = 1 Ractor）なので別に測って出す。
mk = bmeasure(OBJECTS) { OBJECTS.times.map { Cell.new } }
objs = mk.value
puts bline("Cell.new (= 1 Ractor)", mk, unit: "obj")

gate = Ractor::Port.new
done = Ractor::Port.new
pairs = objs.map do |o|
  Ractor.new(o, gate, done, PER) do |ob, g, d, n|
    ob.bump
    g << :ready
    Ractor.receive
    n.times { ob.bump }
    d << :done
  end
end
OBJECTS.times { gate.receive }

total = OBJECTS * PER
m = bmeasure(total) do
  pairs.each { _1.send(:go) }
  OBJECTS.times { done.receive }
end
pairs.each { _1.value rescue nil }
puts brate(format("objects=%-3d", OBJECTS), m)
