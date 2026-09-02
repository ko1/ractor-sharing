# frozen_string_literal: true
#
# A production-shaped logger: callers fire and forget, the owner BATCHES --
# it buffers lines and writes the file only when the buffer fills or grows
# stale, so six hundred log calls become a handful of write syscalls.
#
# Notice how little machinery this takes: the buffer, the high-water mark and
# the "when did I last flush" clock are ordinary ivars, because the owner is
# the only one who ever touches them. The batching policy is just an if.
#
#   ruby -Ilib examples/13_buffered_logger.rb
Warning[:experimental] = false
require "ractor/sharing"
require "tempfile"

class BufferedLogger < Ractor::ActiveObject
  FLUSH_AT    = 64     # lines
  FLUSH_AFTER = 0.05   # seconds without a flush

  def initialize(path)
    @io = File.open(path, "a")
    @buf = []
    @last_flush = now
    @writes = 0        # actual write syscalls, to show the batching
  end

  async def log(line)
    @buf << "#{line}\n"
    flush! if @buf.size >= FLUSH_AT || now - @last_flush > FLUSH_AFTER
  end

  # For quiet periods: anybody may poke the logger now and then, and stale
  # lines go out even when nothing new arrives.
  async def tick
    flush! if @buf.any? && now - @last_flush > FLUSH_AFTER
  end

  sync def close
    flush!
    @io.fsync
    @io.close
    @writes
  end

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def flush!
    return if @buf.empty?

    @io.write(@buf.join)   # one syscall for the whole batch
    @writes += 1
    @buf.clear
    @last_flush = now
  end
end

file = Tempfile.create(["app", ".log"])
file.close
logger = BufferedLogger.new(file.path)

workers = 4.times.map do |i|
  Ractor.new(logger, i) do |log, id|
    150.times { |seq| log.log("w#{id} seq=#{seq}") }   # never waits for the disk
    :ok
  end
end
ticker = Thread.new { 5.times { sleep 0.02; logger.tick } }

workers.each(&:join)
ticker.join
writes = logger.close

lines = File.readlines(file.path, chomp: true)
abort "lines lost: #{lines.size}" unless lines.size == 600
# The owner serializes, and ports are FIFO per sender: each worker's own lines
# land in the file in the order it logged them.
4.times do |id|
  seqs = lines.filter_map { |l| $1.to_i if l =~ /\Aw#{id} seq=(\d+)\z/ }
  abort "w#{id} lines reordered or lost" unless seqs == (0...150).to_a
end
abort "no batching happened: #{writes} writes" unless writes < 600 / 8
File.unlink(file.path)
puts "ok: 600 log calls became #{writes} write syscalls; every worker's lines in order"
