# frozen_string_literal: true
#
# 同じ仕事を族の全クラスにやらせて、値段を並べる。README の「同じ状態に、
# 値段の違う選択肢」がそのまま数字になる。
#
# 仕事は **共有された 1 個のレコードの読み書き**。値は凍った Hash
# `{status:, seq:}` で、write はそれを差し替える、read はそれを取り出す。
# increment を仕事にしないのは、TVar も LockVar も Fixnum 専用の近道を持って
# いて、その 1 行だけが速く見えるから（近道どうしの比較は最後の表で別に出す）。
#
#   read     取り出すだけ。実アプリではこちらが多い
#   write    新しい凍った Hash に差し替える
#   mix 9:1  10 回に 1 回だけ write
#
# これを 2 つの条件で測る:
#
#   conflict     C 個の Ractor が **同じ** 1 個を触る（そこが直列化点になる）
#   no conflict  C 個の Ractor が **自分専用の** 1 個を触る（競合ゼロの対照）
#
# 指標は **全 Ractor 合計での 1 操作あたり**（wall / (C * PER)）。Ractor を倍に
# して半分になればスケールしている。conflict 側は原理的にスケールしないので、
# そこで見るのは「1 個の対象をどれだけ速く通せるか」。
#
# 所有者 Ractor を持つ対象（ActorHash / ActiveObject）は write を async でも
# 出す。返事を待たない分だけ安いが、その分は測定窓の中で読み戻して確定させる。
#
# Ractor の起動コストは含めない: 全員を作って receive で待たせてから時計を始める。
#
# write と mix は毎回 seq を検算する。取りこぼしや no-op が「速い」に化けるのが
# この手の harness で一番たちが悪いので、合わなければその場で落とす。
#
#   ruby family.rb                     # C = 1,2,4,8,16 を掃く
#   BENCH_C=8 ruby family.rb           # 8 だけ
#   BENCH_CS=1,16 ruby family.rb       # 指定した並行度だけ
#   BENCH_SCALE=10 ruby family.rb      # 仕事量を 1/10 に
#   PART=fastpath ruby family.rb       # increment の近道の表だけ
require_relative "lib/bench"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
Warning[:experimental] = false
require "ractor/sharing"

# 1 操作の値段が対象ごとに 100 倍違うので、反復数も対象ごとに持つ。
# PER を指定すると全対象でそれに揃える（比較条件を完全に揃えたいとき用）。
FAST = bscale(Integer(ENV["PER"] || 30_000))
SLOW = bscale(Integer(ENV["PER"] || 2_000))
CS   = ENV["BENCH_C"] ? [bconc(8)] : (ENV["BENCH_CS"] || "1,2,4,8,16").split(",").map(&:to_i)
PART = ENV.fetch("PART", "all")   # all | record | fastpath

REC = { status: :running, seq: 1 }.freeze   # seq は 1 始まり: read の検算が 0 に化けない
MIX = 10                                    # mix は MIX 回に 1 回 write

# 床: 同期の無い ivar。Ractor ごとに自分のを作るので conflict 側も同じ値になる。
class Cell
  def initialize = @rec = REC
  def value = @rec
  def bump = (@rec = { status: @rec[:status], seq: @rec[:seq] + 1 }.freeze)
end

class Record < Ractor::ActiveObject
  def initialize = @rec = REC
  sync  def value = @rec
  # 本体は書き下す。共通メソッドに切り出すと、この 2 行だけ dispatch が 1 段増える。
  sync  def bump = (@rec = { status: @rec[:status], seq: @rec[:seq] + 1 }.freeze)
  async def bump_async = (@rec = { status: @rec[:status], seq: @rec[:seq] + 1 }.freeze)
end

# read/write は shareable proc。全対象が同じ「proc 呼び出し 1 回」を通るので、
# 呼び出しの分の下駄は揃っている。
BUMP_HASH = Ractor.shareable_proc { |h| v = h[:rec]; h[:rec] = { status: v[:status], seq: v[:seq] + 1 }.freeze }

SUBJECTS = [
  { label: "local ivar (floor)", per: FAST, make: -> { nil },
    local: Ractor.shareable_proc { Cell.new },
    read:  Ractor.shareable_proc { |o| o.value[:seq] },
    write: Ractor.shareable_proc { |o| o.bump },
    seq:   Ractor.shareable_proc { |o| o.value[:seq] } },

  { label: "LockVar", per: FAST, make: -> { Ractor::LockVar.new(REC) },
    read:  Ractor.shareable_proc { |o| o.value[:seq] },
    write: Ractor.shareable_proc { |o| o.update { { status: it[:status], seq: it[:seq] + 1 }.freeze } },
    seq:   Ractor.shareable_proc { |o| o.value[:seq] } },

  { label: "TVar", per: FAST, make: -> { Ractor::TVar.new(REC) },
    read:  Ractor.shareable_proc { |o| o.value[:seq] },
    write: Ractor.shareable_proc { |o|
             Ractor.atomically { v = o.value; o.value = { status: v[:status], seq: v[:seq] + 1 }.freeze } },
    seq:   Ractor.shareable_proc { |o| o.value[:seq] } },

  { label: "LockHash", per: FAST, make: -> { Ractor::LockHash.new(rec: REC) },
    read:  Ractor.shareable_proc { |o| o[:rec][:seq] },
    write: Ractor.shareable_proc { |o| o.synchronize(&BUMP_HASH) },
    seq:   Ractor.shareable_proc { |o| o[:rec][:seq] } },

  { label: "ActorHash#call", per: SLOW, make: -> { Ractor::ActorHash.new(rec: REC) },
    read:  Ractor.shareable_proc { |o| o[:rec][:seq] },
    write: Ractor.shareable_proc { |o| o.call(&BUMP_HASH) },
    seq:   Ractor.shareable_proc { |o| o[:rec][:seq] } },

  { label: "ActorHash#async_call", per: SLOW, make: -> { Ractor::ActorHash.new(rec: REC) },
    read:  Ractor.shareable_proc { |o| o[:rec][:seq] },
    write: Ractor.shareable_proc { |o| o.async_call(&BUMP_HASH) },
    flush: Ractor.shareable_proc { |o| o[:rec] },   # 送りっぱなしを測定窓の中で確定させる
    seq:   Ractor.shareable_proc { |o| o[:rec][:seq] } },

  { label: "ActiveObject sync", per: SLOW, make: -> { Record.new },
    read:  Ractor.shareable_proc { |o| o.value[:seq] },
    write: Ractor.shareable_proc { |o| o.bump },
    seq:   Ractor.shareable_proc { |o| o.value[:seq] } },

  { label: "ActiveObject async", per: SLOW, make: -> { Record.new },
    read:  Ractor.shareable_proc { |o| o.value[:seq] },
    write: Ractor.shareable_proc { |o| o.bump_async },
    flush: Ractor.shareable_proc { |o| o.value },
    seq:   Ractor.shareable_proc { |o| o.value[:seq] } },
]

# increment はどちらのクラスでも特別扱いされていて、Fixnum どうしの和が Fixnum に
# 収まるときは Ruby を一切走らせずに足して返す近道を通る
# (tvar.c tvar_calc_inc / lockvar.c lockvar_fixnum_add)。上のレコードの表とは
# 別の土俵なので、表も分けてある。
IVAL = Ractor.shareable_proc { |o| o.value }
FAST_PATH = [
  { label: "LockVar#increment", make: -> { Ractor::LockVar.new(0) },
    write: Ractor.shareable_proc { |o| o.increment }, seq: IVAL },
  { label: "TVar#increment", make: -> { Ractor::TVar.new(0) },
    write: Ractor.shareable_proc { |o| o.increment }, seq: IVAL },
]

MODES = %i[read write mix].freeze

# 1 Ractor あたりの write 回数。read だけのときは 0。
def writes_per(mode, per) = mode == :read ? 0 : (mode == :write ? per : per / MIX)

def run(objs, sub, mode, per)
  gate = Ractor::Port.new
  rs = objs.map do |obj|
    Ractor.new(obj, gate, sub[:local], sub[:read], sub[:write], sub[:flush], per, mode, MIX) do
      |o, g, mk, rd, wr, fl, n, m, mix|
      o ||= mk.call
      g << :ready                         # 起動も Cell.new も測定窓の外へ
      Ractor.receive                       # go を待つ
      sum = 0
      case m
      when :read  then n.times { sum += rd.call(o) }
      when :write then n.times { wr.call(o) }
      else             n.times { |i| (i % mix == mix - 1) ? wr.call(o) : sum += rd.call(o) }
      end
      # 送りっぱなしを自分で確定させる。所有者は届いた順に処理するので、自分の
      # 同期読みが返れば自分の送りは全部済んでいる。coordinator にまとめてやらせると
      # no conflict のとき C 回の直列往復が測定窓に乗ってしまう。
      fl&.call(o)
      [sum, rd.call(o)]
    end
  end
  objs.size.times { gate.receive }        # 全員が receive の手前まで来た
  m = bmeasure(objs.size * per) do
    rs.each { |r| r.send(:go) }
    rs.map(&:value)
  end
  verify(objs, sub, mode, per, m.value)
  m
end

# 検算。壊れた測定が「速い」に見えるのを塞ぐ。worker は [read の合計, 最後に
# 読んだ seq] を返す。後者があるので、床のように外から触れない対象も検算できる。
def verify(objs, sub, mode, per, results)
  sums = results.map(&:first)
  lasts = results.map(&:last)
  w = writes_per(mode, per)
  reads = per - w

  case mode
  when :read
    want = per * REC[:seq]
    sums.each { |s| abort "#{sub[:label]} read: sum #{s} != #{want}" unless s == want }
  when :mix
    # mix の read は動いている値を見るので合計は決まらない。seq は 1 から増える
    # 一方なので、下限だけは決まる。0 を返す no-op はここで落ちる。
    sums.each do |s|
      abort "#{sub[:label]} mix: read sum #{s} < #{reads}" unless s >= reads
    end
  end
  return if w.zero?

  # worker 自身の最後の読み。対象を独り占めしているときだけ値が決まる（共有して
  # いると、先に終わった worker はまだ書いている他人の途中を読む）。床はここでしか
  # 検算できない: Cell は Ractor の中にしかなく、外から触れない。
  if sub[:local] || objs.uniq.size == objs.size
    want_own = REC[:seq] + w
    lasts.each do |got|
      abort "#{sub[:label]} #{mode}: own seq #{got} != #{want_own} (lost updates)" unless got == want_own
    end
  end
  return if sub[:local]
  objs.uniq.each do |o|
    want = REC[:seq] + w * objs.count { |x| x.equal?(o) }
    got = sub[:seq].call(o)
    abort "#{sub[:label]} #{mode}: seq #{got} != #{want} (lost updates)" unless got == want
  end
end

def run_fast_path(objs, sub, per)
  gate = Ractor::Port.new
  rs = objs.map do |obj|
    Ractor.new(obj, gate, sub[:write], per) do |o, g, wr, n|
      g << :ready
      Ractor.receive
      n.times { wr.call(o) }
      nil
    end
  end
  objs.size.times { gate.receive }
  m = bmeasure(objs.size * per) { rs.each { |r| r.send(:go) }; rs.each(&:join) }
  objs.uniq.each do |o|
    want = per * objs.count { |x| x.equal?(o) }
    got = sub[:seq].call(o)
    abort "#{sub[:label]}: #{got} != #{want} (lost updates)" unless got == want
  end
  m
end

def make_objs(c, sub, cond)
  if cond == :conflict
    shared = sub[:make].call
    Array.new(c) { shared }
  else
    Array.new(c) { sub[:make].call }      # conflict 側の 1 個をここで作らない:
  end                                     # 所有者 Ractor は止められないので残り続ける
end

def sweep(c, sub, per)
  MODES.flat_map do |mode|
    [:conflict, :noconflict].map do |cond|
      run(make_objs(c, sub, cond), sub, mode, per).per_op_us * 1000
    end
  end
end

puts RUBY_DESCRIPTION
puts "family: shared record {status:, seq:}   n=#{FAST}/#{SLOW} per ractor   ns per completed op (all Ractors)"
puts "mix = #{MIX - 1} reads : 1 write"

CS.each do |c|
  next unless %w[all record].include?(PART)
  puts
  printf("%-22s %-33s %s\n", "", "conflict (same object)", "no conflict (own object)")
  printf("%-22s %11s %11s %11s %11s %11s %11s\n", "C=#{c}",
         "read", "write", "mix 9:1", "read", "write", "mix 9:1")
  SUBJECTS.each do |sub|
    r = sweep(c, sub, sub[:per])
    printf("%-22s %8.0f ns %8.0f ns %8.0f ns %8.0f ns %8.0f ns %8.0f ns\n",
           sub[:label], r[0], r[2], r[4], r[1], r[3], r[5])
  end
end

if %w[all fastpath].include?(PART)
puts
puts "increment: both classes take a Fixnum-only fast path here, adding two"
puts "Fixnums without running any Ruby, so this is a separate comparison from"
puts "the record table above."
CS.each do |c|
  puts
  printf("%-32s %12s %12s\n", "C=#{c}", "conflict", "no conflict")
  FAST_PATH.each do |sub|
    row = [:conflict, :noconflict].map do |cond|
      run_fast_path(make_objs(c, sub, cond), sub, FAST).per_op_us * 1000
    end
    printf("%-32s %10.0f ns %9.0f ns\n", sub[:label], row[0], row[1])
  end
end
end
