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

  # The book is copy-on-write: each subscribe rebuilds the topic's array, so
  # it costs O(subscribers) -- measured, the ten-thousandth subscribe is not
  # quite double the thousandth (the copy is cheap next to the lock and the
  # walk). Fine into the thousands; a topic with tens of thousands of churning
  # subscribers is mutable state, i.e. the owner version (18), whose append
  # stays flat however large the book grows.
  # The port must be created by the subscriber: only its creator may receive.
  def subscribe(topic, port)
    @topics.update(topic) {|ports| (ports || []) + [port] }
    port
  end

  # Leaving politely, while alive: the lazy pruning below only notices death.
  def unsubscribe(topic, port)
    @topics.update(topic) {|ports| (ports || []) - [port] }
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

  # The stored array itself: frozen on the way in, so it crosses anywhere and
  # nobody can bend it -- a true snapshot, stale the moment after. Think before
  # making this public, though: a port is the capability to send to that
  # subscriber, and a listing hands every caller a way around #publish.
  def ports(topic) = @topics[topic] || []

  # The channel list is the key list: a copy, consistent per key. A topic whose
  # last subscriber died lingers as topic => [] -- removing the key the moment
  # it empties would take two acquisitions (see the emptiness, then delete),
  # and a new subscriber can land in between. Per-key locking cannot say
  # "delete if still empty" atomically; filtering the listing can.
  def channels = @topics.keys.select {|t| (@topics[t] || []).any? }
end

BUS = PubSub.new

listeners = 4.times.map do |i|
  Ractor.new(BUS, i) do |bus, id|
    port = bus.subscribe("deploys", Ractor::Port.new)
    case id
    when 2 then (port.receive; [:died])      # exits; its closed port gets pruned
    when 3                                   # listens once, then leaves politely
      msg = port.receive
      bus.unsubscribe("deploys", port)
      [:unsubscribed, msg]
    else 3.times.map { port.receive }
    end
  end
end
sleep 0.05                                   # let the subscriptions land

first = BUS.publish("deploys", "v1 is live")
abort "expected 4 deliveries, got #{first}" unless first == 4
abort "polite leaver broke" unless listeners[3].value == [:unsubscribed, "v1 is live"]
listeners[2].value                           # subscriber 2 exits; its port closes

rest = 2.times.map { |n| BUS.publish("deploys", "v#{n + 2} is live") }
heard = listeners[0..1].map(&:value)
abort "a live subscriber missed a message: #{heard}" unless heard.all? { |h| h == ["v1 is live", "v2 is live", "v3 is live"] }
abort "the dead subscriber was not pruned" unless BUS.subscribers("deploys") == 2
deploy_ports = BUS.ports("deploys")
abort "port list wrong" unless deploy_ports.size == 2 && deploy_ports.frozen? &&
                               deploy_ports.all?(Ractor::Port)
BUS.subscribe("alerts", Ractor::Port.new)
abort "channel list wrong: #{BUS.channels}" unless BUS.channels.sort == %w[alerts deploys]
puts "ok: 3 published, #{[first, *rest].join('+')} delivered; one leaver pruned, " \
     "one unsubscribed politely, and both stayers heard every message in order"
