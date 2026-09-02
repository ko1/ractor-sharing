# frozen_string_literal: true
#
# Map-reduce with a mutable reduce side: workers count their chunk locally,
# then send the merge to the ActorHash as work. The tallies live unfrozen in
# the owner Ractor and are bumped in place -- no freezing a Hash per update,
# which is what the lock family would have demanded.
#
#   ruby -Ilib examples/07_word_count.rb
Warning[:experimental] = false
require "ractor/sharing"

TEXT = ("the quick brown fox jumps over the lazy dog " * 50 +
        "sator arepo tenet opera rotas " * 30).freeze
CHUNKS = TEXT.scan(/(?:\S+\s*){1,40}/).map(&:freeze).freeze

tally = Ractor::ActorHash.new

workers = 4.times.map do |i|
  Ractor.new(tally, CHUNKS, i) do |t, chunks, offset|
    chunks.each_with_index do |chunk, j|
      next unless j % 4 == offset

      counts = chunk.split.tally
      # Fire and forget: the block runs on the owner, against the real hash.
      t.async_call(counts) { |h, c| c.each { |w, n| h[w] = (h[w] || 0) + n } }
    end
    t[:the]   # one sync read = my merges have all landed (per-sender FIFO)
    :ok
  end
end
workers.each(&:join)

expected = TEXT.split.tally
got = tally.to_h
abort "tallies differ" unless got == expected
puts "ok: #{got.values.sum} words, #{got.size} distinct; 'the' => #{got['the']}, 'tenet' => #{got['tenet']}"
