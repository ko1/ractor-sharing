# frozen_string_literal: true
#
# The other pub/sub, and the trade between them. 17_pubsub.rb delivers from
# the publisher's own Ractor: publishers run in parallel, and the only order
# is each publisher's own. Here the broker is an ActiveObject, so every
# publish funnels through one owner -- publishers pay a send and the broker
# caps throughput, and what that buys is TOTAL ORDER: every subscriber sees
# the exact same sequence, however many publishers race.
#
#   ruby -Ilib examples/18_pubsub_ordered.rb
Warning[:experimental] = false
require "ractor/sharing"

class OrderedPubSub < Ractor::ActiveObject
  def initialize = @topics = {}          # a plain mutable Hash: it never leaves

  # Returns nil on purpose: a sync reply crosses back to the caller, and an
  # unshareable return is copied whole -- return the book here and every
  # subscribe ships a copy of the entire, growing subscriber list. Measured,
  # that one mistake made the ten-thousandth subscribe five times the cost of
  # the call itself, and rising with every subscriber after.
  sync def subscribe(topic, port) = ((@topics[topic] ||= []) << port; nil)

  async def publish(topic, message)      # fire and forget; the owner serializes
    (@topics[topic] || []).each { |port| port << message }
  end
end

BUS = OrderedPubSub.new

subscribers = 3.times.map do
  Ractor.new(BUS) do |bus|
    port = Ractor::Port.new
    bus.subscribe("ticker", port)        # sync: subscribed before we say ready
    40.times.map { port.receive }
  end
end
sleep 0.05                               # let all three subscriptions land

publishers = %w[alpha beta].map do |name|
  Ractor.new(BUS, name) do |bus, me|
    20.times { |i| bus.publish("ticker", "#{me}-#{i}") }
    :ok
  end
end
publishers.each(&:join)

feeds = subscribers.map(&:value)
abort "someone missed messages" unless feeds.all? { |f| f.size == 40 }
abort "subscribers saw DIFFERENT orders" unless feeds.uniq.size == 1
%w[alpha beta].each do |name|
  seq = feeds.first.grep(/\A#{name}/)
  abort "#{name}'s own order broken" unless seq == 20.times.map { "#{name}-#{_1}" }
end
puts "ok: two publishers raced 40 messages; all three subscribers saw the " \
     "identical sequence -- the total order one owner buys"
