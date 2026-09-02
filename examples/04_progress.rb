# frozen_string_literal: true
#
# A shared progress counter: workers add what they finished, the main Ractor
# reads it whenever it feels like drawing the bar. increment is atomic, value
# is just a peek -- nobody coordinates with anybody.
#
#   ruby -Ilib examples/04_progress.rb
Warning[:experimental] = false
require "ractor/sharing"

TOTAL = 4 * 200
done = Ractor::LockVar.new(0)

workers = 4.times.map do
  Ractor.new(done) do |d|
    200.times do
      # pretend to move some bytes
      d.increment
    end
    :ok
  end
end

bars = []
until (n = done.value) == TOTAL
  bars << "[#{'#' * (n * 20 / TOTAL)}#{'.' * (20 - n * 20 / TOTAL)}]"
  # the reader sleeps; the writers never wait for it
  sleep 0.001
end
workers.each(&:join)

abort "lost updates: #{done.value}" unless done.value == TOTAL
puts "ok: #{bars.size} redraw(s) while counting to #{TOTAL}, e.g. #{bars[bars.size / 2]}"
