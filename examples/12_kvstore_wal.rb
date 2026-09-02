# frozen_string_literal: true
#
# A crash-safe key-value store: every write is appended to a write-ahead log
# on disk before anything else sees it, then the process "crashes" and a fresh
# store replays the log -- and must arrive at the identical state.
#
# The store is an ActiveObject rather than an ActorHash for one load-bearing
# reason: THE STORE ITSELF writes its log, inside its own owner, so the log
# order and the apply order are the same order by construction. Writers are
# async (a set does not wait for the disk); reads are sync; sync def flush is
# the durability barrier.
#
#   ruby -Ilib examples/12_kvstore_wal.rb
Warning[:experimental] = false
require "ractor/sharing"
require "tempfile"

class KVStore < Ractor::ActiveObject
  def initialize(wal_path, replay: false)
    @h = {}
    @wal = File.open(wal_path, replay ? "r" : "w")
    if replay
      @wal.each_line do |line|
        op, key, arg = line.chomp.split("\t", 3)
        apply(op, key, arg)
      end
      @wal.close
      @wal = nil
    end
  end

  async def set(key, value) = log_and_apply("set", key, value.to_s)
  async def incr(key, by = 1) = log_and_apply("incr", key, by.to_s)
  async def del(key) = log_and_apply("del", key)

  sync def get(key) = @h[key]
  sync def snapshot = @h.dup
  sync def flush = (@wal&.fsync; @h.size)   # the barrier: everything before is on disk

  private

  def log_and_apply(op, key, arg = nil)
    @wal.puts([op, key, arg].compact.join("\t"))
    apply(op, key, arg)
  end

  def apply(op, key, arg)
    case op
    when "set"  then @h[key] = arg
    when "incr" then @h[key] = (@h[key] || "0").to_i + Integer(arg)
    when "del"  then @h.delete(key)
    end
  end
end

wal = Tempfile.create(["kvstore", ".wal"])
wal.close

store = KVStore.new(wal.path)

writers = 4.times.map do |i|
  Ractor.new(store, i) do |s, id|
    100.times do |j|
      s.set("user:#{id}:name", "shopper-#{id}")
      s.incr("hits")
      s.incr("user:#{id}:visits")
      s.del("user:#{id}:name") if j == 50
    end
    s.flush   # my writes are applied and on disk
    :ok
  end
end
writers.each(&:join)

before = store.snapshot
abort "hits wrong: #{before}" unless before["hits"] == 400

# The crash: the store object is simply abandoned. All we hold is the file.
recovered = KVStore.new(wal.path, replay: true).snapshot

abort "recovery diverged:\n  live    #{before}\n  replay  #{recovered}" unless recovered == before
File.unlink(wal.path)
puts "ok: #{before.size} keys survived the crash byte for byte; " \
     "hits=#{recovered['hits']}, wal replayed from #{File.basename(wal.path)}"
