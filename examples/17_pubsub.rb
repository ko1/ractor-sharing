# frozen_string_literal: true
#
# Pub/sub in thirty lines, and the reason this gem does not ship one: it is
# the family and the language composing. The subscription book is state --
# a KeyLockHash of topic => ports, updated per key -- and delivery is what
# Ractor::Port already does. A subscriber waits in the one place a Ractor
# ever waits: its own port's receive.
#
# A Ractor::Port is shareable, so it can sit in the book directly; a
# subscriber that died closed its port, and the next publish prunes it.
#
# Publishers run in parallel and pay their own delivery; the only order is
# each publisher's own. When every subscriber must see the SAME order, that
# is what an owner buys: see 18_pubsub_ordered.rb.
#
#   ruby -Ilib examples/17_pubsub.rb
Warning[:experimental] = false
require "ractor/sharing"

class PubSub
  def initialize
    @topics = Ractor::KeyLockHash.new
    Ractor.make_shareable(self)
  end

  # The port must be created by the subscriber: only its creator may receive.
  def subscribe(topic, port)
    @topics.update(topic) {|ports| (ports || []) + [port] }
    port
  end

  def publish(topic, message)
    dead = nil
    delivered = 0
    (@topics[topic] || []).each do |port|
      port << message
      delivered += 1
    rescue Ractor::ClosedError
      (dead ||= []) << port                  # subscriber gone; prune below
    end
    @topics.update(topic) {|ports| (ports || []) - dead } if dead
    delivered
  end

  def subscribers(topic) = (@topics[topic] || []).size
end

BUS = PubSub.new

listeners = 3.times.map do |i|
  Ractor.new(BUS, i) do |bus, id|
    port = bus.subscribe("deploys", Ractor::Port.new)
    port.receive if id == 2                  # this one leaves after a single message
    id == 2 ? [:left_early] : 3.times.map { port.receive }
  end
end
sleep 0.05                                   # let the subscriptions land

first = BUS.publish("deploys", "v1 is live")
abort "expected 3 deliveries, got #{first}" unless first == 3
listeners[2].value                           # subscriber 2 exits; its port closes

rest = 2.times.map { |n| BUS.publish("deploys", "v#{n + 2} is live") }
heard = listeners[0..1].map(&:value)
abort "a live subscriber missed a message: #{heard}" unless heard.all? { |h| h == ["v1 is live", "v2 is live", "v3 is live"] }
abort "the dead subscriber was not pruned" unless BUS.subscribers("deploys") == 2
puts "ok: 3 published, #{[first, *rest].join('+')} delivered; the one that left was " \
     "pruned on the next publish, and both stayers heard every message in order"
