# frozen_string_literal: true
#
# Booking two adjacent seats. With one lock per seat this is the textbook
# deadlock: two buyers taking overlapping pairs in opposite order wait on each
# other forever. With TVars there is no lock order to get wrong: the loser of a
# race is rolled back and simply looks again.
#
#   ruby -Ilib examples/02_seat_booking.rb
Warning[:experimental] = false
require "ractor/sharing"

SEATS = Ractor.make_shareable(Array.new(10) { Ractor::TVar.new(:free) })

buyers = %i[ann ben cho dee].map do |name|
  Ractor.new(SEATS, name) do |seats, me|
    # One transaction: find the first adjacent free pair and take both.
    # Everybody scans in a different direction on purpose -- the opposite-order
    # access that would deadlock locks is just contention here.
    Ractor.atomically do
      range = (0...seats.size - 1)
      range = range.to_a.reverse if %i[ben dee].include?(me)
      i = range.find { |j| seats[j].value == :free && seats[j + 1].value == :free }
      next nil if i.nil?

      seats[i].value = me
      seats[i + 1].value = me
      i
    end
  end
end

got = buyers.map(&:value)
taken = SEATS.map(&:value)
abort "somebody got no pair: #{taken}" if got.any?(&:nil?)
got.each do |i|
  a, b = taken[i], taken[i + 1]
  abort "pair at #{i} torn: #{taken}" unless a == b && a != :free
end
abort "double booking: #{taken}" unless taken.tally.values.all? { |n| n <= 2 }
puts "ok: #{taken.each_slice(2).map { |s| s.map { |v| v == :free ? '__' : v[0, 2] }.join }.join(' | ')}"
