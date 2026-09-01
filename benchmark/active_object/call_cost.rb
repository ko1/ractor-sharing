# frozen_string_literal: true
#
# 1 呼び出しの値段を policy 別に、分母つきで出す。このライブラリの看板の数字。
#
#   ruby benchmark/call_cost.rb
#
# 分母を必ず一緒に取る（これが無いと「9us は速いのか」に答えられない）:
#   plain        proxy を通さない素の method call = 言語の床
#   mutex_thread Mutex で守ったオブジェクトを別スレッドから叩く 1:1 の対照
#   port_rt      Ractor::Port の生の往復 = ActiveObject が払える下限
#   owner_direct owner Ractor 自身から呼ぶ（proxy でも servant 直呼びになる経路）
#
# sync は往復、async は片道（送っただけで返る）なので、async の us/call は
# 「呼び手が払う額」であって処理が終わった時刻ではない。最後に sync を 1 回
# 入れてキューを空にしてから止める（README の barrier 規約）。
Warning[:experimental] = false
require_relative "../lib/bench"
require_relative "../../lib/ractor/active_object"

N = bscale(Integer(ENV.fetch("N", 50_000)))

class Counter < Ractor::ActiveObject
  def initialize = @n = 0
  sync   def get      = @n
  sync   def bump     = @n += 1
  async  def bump_a   = @n += 1
  future def bump_f   = @n += 1
  sync   def nop      = nil
  # servant 側の自己呼び出し: owner Ractor の中では mailbox を通らず素の call になる。
  # 1 回の sync でまとめて回し、往復ぶんを引いて 1 呼び出しの値段を出す。
  sync   def bump_n(k) = k.times { bump }
end

class PlainCounter
  def initialize = @n = 0
  def bump = @n += 1
end

puts RUBY_DESCRIPTION
puts "policy 別 1 呼び出しコスト  N=#{N}"

# --- 床 1: proxy を通さない素の呼び出し
plain = PlainCounter.new
bwarm(2000).times { plain.bump }
puts bline("plain method", bmeasure(N) { N.times { plain.bump } })

# --- 床 2: Mutex で守った同じものを別スレッドから（1:1 の対照）
mtx = Mutex.new
shared = PlainCounter.new
q, r = Queue.new, Queue.new
th = Thread.new { loop { break if q.pop == :stop; mtx.synchronize { shared.bump }; r << :ok } }
bwarm(2000).times { q << :go; r.pop }
puts bline("mutex + thread", bmeasure(N) { N.times { q << :go; r.pop } })
q << :stop; th.join

# --- 床 3: Ractor::Port の生往復（ActiveObject が払える下限）
boot = Ractor::Port.new
echo = Ractor.new(boot) do |b|
  me = Ractor::Port.new
  b << me
  while (m = me.receive) != :stop
    m[0] << m[1]
  end
end
peer = boot.receive
back = Ractor::Port.new
bwarm(2000).times { peer << [back, 1]; back.receive }
puts bline("raw Port round trip", bmeasure(N) { N.times { peer << [back, 1]; back.receive } })
peer << :stop
echo.value rescue nil

# --- ActiveObject 本体
c = Counter.new
bwarm(2000).times { c.bump }
puts bline("ao sync", bmeasure(N) { N.times { c.bump } })

bwarm(2000).times { c.nop }
puts bline("ao sync (nop)", bmeasure(N) { N.times { c.nop } })

# async は片道。最後に sync barrier を 1 回入れてキューを空にしてから止める。
bwarm(2000).times { c.bump_a }; c.nop
m = bmeasure(N) { N.times { c.bump_a }; c.nop }
puts bline("ao async (+1 barrier)", m)

# future は毎回新しい reply port を取る（sync は Ractor-local プールから借りる）。
bwarm(500).times { c.bump_f.value }
puts bline("ao future (value)", bmeasure(N) { N.times { c.bump_f.value } })

# 投げてから後でまとめて回収する形。future の意味はこちら。
DEPTH = Integer(ENV.fetch("DEPTH", 64))
bwarm(500).times { c.bump_f.value }
m = bmeasure(N) do
  (N / DEPTH).times do
    fs = DEPTH.times.map { c.bump_f }
    fs.each(&:wait)
  end
end
puts bline("ao future (depth=#{DEPTH})", m)

# --- servant 側の自己呼び出し（owner Ractor の中なので mailbox を通らない）
c.bump_n(bwarm(2000))
m = bmeasure(N) { c.bump_n(N) }
puts bline("ao servant self-call", m, extra: "sync 1 回の中で N 回。mailbox を通らない経路")
