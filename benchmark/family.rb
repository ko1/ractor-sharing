# frozen_string_literal: true
#
# 同じ仕事を族の全クラスにやらせて、値段を並べる。README の「同じ状態に、
# 値段の違う選択肢」がそのまま数字になる。
#
# 仕事はカウンタの increment ひとつ。2 つの条件で測る:
#
#   conflict     C 個の Ractor が **同じ** 1 個を増やす（そこが直列化点になる）
#   no conflict  C 個の Ractor が **自分専用の** 1 個を増やす（競合ゼロの対照）
#
# 指標は **全 Ractor 合計での 1 操作あたり**（wall / (C * PER)）。Ractor を倍に
# して半分になればスケールしている。conflict 側は原理的にスケールしないので、
# そこで見るのは「1 個の対象をどれだけ速く通せるか」。
#
# Ractor の起動コストは含めない: 全員を作って receive で待たせてから時計を
# 始める。async な対象は、測定窓の中で読み戻して未処理を確定させる。
#
#   ruby family.rb                     # C = 1,2,4,8,16 を掃く
#   BENCH_C=8 ruby family.rb           # 8 だけ
#   BENCH_SCALE=10 ruby family.rb      # 仕事量を 1/10 に
require_relative "lib/bench"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
Warning[:experimental] = false
require "ractor/sharing"

# 1 操作の値段が対象ごとに 100 倍違うので、反復数も対象ごとに持つ。
# PER を指定すると全対象でそれに揃える（比較条件を完全に揃えたいとき用）。
FAST = bscale(Integer(ENV["PER"] || 50_000))
SLOW = bscale(Integer(ENV["PER"] || 3_000))
CS  = ENV["BENCH_C"] ? [bconc(8)] : (ENV["BENCH_CS"] || "1,2,4,8,16").split(",").map(&:to_i)

class Counter < Ractor::ActiveObject
  def initialize = @n = 0
  sync def incr = (@n += 1)
  sync def value = @n
end

# [ラベル, 反復数, 入れ物を 1 つ作る, 1 操作(shareable proc), 送りっぱなしを確定させる読み]
SUBJECTS = [
  ["local ivar (floor)", FAST, -> { nil }, nil, nil],
  ["LockVar#increment",  FAST, -> { Ractor::LockVar.new(0) },
   Ractor.shareable_proc { |o| o.increment }, nil],
  ["LockVar#update",     FAST, -> { Ractor::LockVar.new(0) },
   Ractor.shareable_proc { |o| o.update { it + 1 } }, nil],
  ["LockHash#synchronize", FAST, -> { Ractor::LockHash.new(n: 0) },
   Ractor.shareable_proc { |o| o.synchronize { |h| h[:n] += 1 } }, nil],
  ["TVar#increment",     FAST, -> { Ractor::TVar.new(0) },
   Ractor.shareable_proc { |o| o.increment }, nil],
  ["TVar atomically",    FAST, -> { Ractor::TVar.new(0) },
   Ractor.shareable_proc { |o| Ractor.atomically { o.value += 1 } }, nil],
  ["ActorHash#increment (async)", SLOW, -> { Ractor::ActorHash.new(n: 0) },
   Ractor.shareable_proc { |o| o.increment(:n) },
   Ractor.shareable_proc { |o| o[:n] }],
  ["ActorHash#call",     SLOW, -> { Ractor::ActorHash.new(n: 0) },
   Ractor.shareable_proc { |o| o.call { |h| h[:n] += 1 } }, nil],
  ["ActiveObject#sync",  SLOW, -> { Counter.new },
   Ractor.shareable_proc { |o| o.incr }, nil],
]

def run(objs, op, flush, per)
  rs = objs.map do |obj|
    Ractor.new(obj, op, per) do |o, f, n|
      Ractor.receive                      # go を待つ = 起動コストを外に出す
      if f
        n.times { f.call(o) }
      else
        x = 0
        n.times { x += 1 }
      end
      :ok
    end
  end
  bmeasure(objs.size * per) do
    rs.each { |r| r.send(:go) }
    rs.each(&:join)
    objs.uniq.each { |o| flush.call(o) } if flush
  end
end

puts RUBY_DESCRIPTION
puts "family: counter increment   n=#{FAST}/#{SLOW} per ractor   ns per completed op (all Ractors)"

CS.each do |c|
  puts
  printf("%-30s %12s %12s\n", "C=#{c}", "conflict", "no conflict")
  SUBJECTS.each do |label, per, make, op, flush|
    row = [:conflict, :noconflict].map do |mode|
      shared = make.call
      objs = mode == :conflict ? Array.new(c) { shared } : Array.new(c) { make.call }
      run(objs, op, flush, per).per_op_us * 1000
    end
    printf("%-30s %10.0f ns %9.0f ns\n", label, row[0], row[1])
  end
end
