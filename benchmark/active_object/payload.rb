# frozen_string_literal: true
#
# 引数と戻り値は Ractor 境界を越えるたびにコピーされる（shareable なら参照）。
# その値段をバイト数の関数として出す。BYTES=0 は Integer 1 個（コピーの無い最小形)。
# shareable=1 で凍らせた同じ大きさの値を渡し、コピーの分だけを差として読む。
#
#   BYTES=4096 ruby benchmark/payload.rb
Warning[:experimental] = false
require_relative "../lib/bench"
require_relative "../../lib/ractor/active_object"

BYTES     = Integer(ENV.fetch("BYTES", 0))
SHAREABLE = ENV["SHAREABLE"] == "1"
N         = bscale(Integer(ENV.fetch("N", 20_000)))

class Echo < Ractor::ActiveObject
  def initialize = @last = nil
  sync def ping(v) = v          # 往復ともペイロードが越える
  sync def take(v) = (@last = v; nil)  # 行きだけ
end

payload =
  if BYTES.zero? then 1
  elsif SHAREABLE then Ractor.make_shareable("x" * BYTES)
  else "x" * BYTES
  end

puts RUBY_DESCRIPTION
e = Echo.new
bwarm(2000).times { e.ping(payload) }
label = format("bytes=%-6d %s", BYTES, SHAREABLE ? "shareable" : "copied")
puts bline("#{label} ping", bmeasure(N) { N.times { e.ping(payload) } }, extra: "往復ともコピー")
bwarm(2000).times { e.take(payload) }
puts bline("#{label} take", bmeasure(N) { N.times { e.take(payload) } }, extra: "行きだけ")
