# frozen_string_literal: true
#
# An API gateway: three middlewares you meet in every real backend, each on
# the member of the family that fits it.
#
#   token buckets   LockHash   one frozen {tokens:, at:} record per client,
#                              refilled and debited in one synchronize
#   idempotency     LockHash   "seen this request id?" is an atomic
#                              check-and-claim across keys that grow forever
#   circuit breaker LockVar    one state machine, and the "breaker opened"
#                              audit line fires EXACTLY once per transition,
#                              because an update block never reruns
#
# A request runs the gauntlet in order: bucket -> idempotency -> breaker ->
# upstream. The upstream and the audit trail are ActiveObjects.
#
#   ruby -Ilib examples/14_api_gateway.rb
Warning[:experimental] = false
require "ractor/sharing"

CAPACITY   = 20     # bucket size per client
REFILL     = 50.0   # tokens per second
THRESHOLD  = 5      # consecutive failures that open the breaker
COOLDOWN   = 0.03   # seconds before the breaker lets a probe through

class Upstream < Ractor::ActiveObject
  def initialize = (@hits = Hash.new(0); @down = false)
  sync def set_down(flag) = @down = flag
  sync def call(id) = @down ? :error : (@hits[id] += 1; "resp-#{id}".freeze)
  sync def hits = @hits.dup
end

class Audit < Ractor::ActiveObject
  def initialize = @events = []
  async def event(name) = @events << name
  sync def events = @events.dup
end

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# --- the gateway, called from any Ractor -----------------------------------

def gateway_call(gw, client, id)
  client = -client                  # LockHash keys must be shareable:
  id = -id                          # -string is the frozen, deduped copy

  # 1. Token bucket: refill by elapsed time, take one, all under the hash lock.
  allowed = nil
  gw[:buckets].synchronize do |h|
    rec = h[client] || { tokens: CAPACITY.to_f, at: mono }.freeze
    tokens = [rec[:tokens] + (mono - rec[:at]) * REFILL, CAPACITY.to_f].min
    allowed = tokens >= 1.0
    h[client] = { tokens: allowed ? tokens - 1.0 : tokens, at: mono }.freeze
  end
  return [:rate_limited] unless allowed

  # 2. Idempotency: claim the id or find it done. The claim is atomic; the
  #    handler itself runs outside the lock, so the section stays short.
  #    `mine` is decided INSIDE the synchronize: reading :claimed back out
  #    is not the same thing as having claimed it -- the first draft of this
  #    example confused the two, and two racing retries both executed.
  mine = false
  claim = nil
  gw[:idem].synchronize do |h|
    if h.key?(id)
      claim = h[id]
    else
      h[id] = :claimed
      mine = true
    end
  end
  unless mine
    if claim.is_a?(Symbol)                    # somebody is on it: wait for them
      200.times do
        done = gw[:idem][id]
        return [:cached, done] unless done.is_a?(Symbol)
        sleep 0.001
      end
      abort "idempotency claim never resolved for #{id}"
    end
    return [:cached, claim]                   # already done: same answer again
  end

  # 3. Circuit breaker: decide under the lock, call outside it, record under it.
  state = gw[:breaker].update do |b|
    if b[:state] == :open && mono - b[:opened_at] >= COOLDOWN
      b.merge(state: :half_open).freeze       # one probe may pass
    else
      b
    end
  end
  if state[:state] == :open
    gw[:idem].synchronize { |h| h.delete(id) }  # release the claim: not handled
    return [:circuit_open]
  end

  resp = gw[:upstream].call(id)

  gw[:breaker].update do |b|
    if resp == :error
      f = b[:failures] + 1
      if f >= THRESHOLD && b[:state] != :open
        gw[:audit].event(:breaker_opened)     # runs once: updates never rerun
        { state: :open, failures: f, opened_at: mono }.freeze
      else
        b.merge(failures: f).freeze
      end
    else
      gw[:audit].event(:breaker_closed) if b[:state] == :half_open
      { state: :closed, failures: 0, opened_at: 0.0 }.freeze
    end
  end

  if resp == :error
    gw[:idem].synchronize { |h| h.delete(id) }  # failed calls may be retried
    [:upstream_error]
  else
    gw[:idem].synchronize { |h| h[id] = resp }
    [:ok, resp]
  end
end

GW = Ractor.make_shareable({
  buckets: Ractor::LockHash.new,
  idem: Ractor::LockHash.new,
  breaker: Ractor::LockVar.new({ state: :closed, failures: 0, opened_at: 0.0 }.freeze),
  upstream: Upstream.new,
  audit: Audit.new
})

# --- act 1: the polite and the greedy --------------------------------------
polite, greedy = %w[polite greedy].map do |who|
  Ractor.new(GW, who) do |gw, me|
    n = me == "polite" ? CAPACITY : CAPACITY * 3
    n.times.map { |i| gateway_call(gw, me, "#{me}-#{i}").first }.tally
  end
end
p_tally, g_tally = polite.value, greedy.value
abort "polite got limited: #{p_tally}" unless p_tally == { ok: CAPACITY }
abort "greedy was not limited: #{g_tally}" unless g_tally[:rate_limited] &&
                                                  g_tally[:ok] <= CAPACITY + 3

# --- act 2: at-most-once under retries --------------------------------------
retriers = 3.times.map do |i|
  Ractor.new(GW, i) do |gw, me|
    # Ten ids SHARED by all three clients, each sent twice: 60 requests, and
    # the upstream must see each id exactly once.
    2.times.flat_map { (0...10).map { |k| gateway_call(gw, "retrier#{me}", "order-#{k}") } }
  end
end
responses = retriers.flat_map(&:value)
hits = GW[:upstream].hits
(0...10).each do |k|
  abort "order-#{k} executed #{hits["order-#{k}"]} times" unless hits["order-#{k}"] == 1
  answers = responses.select { |_, r| r == "resp-order-#{k}" }
  abort "order-#{k}: divergent answers" unless answers.size == 6   # 3 clients x 2 tries
end

# --- act 3: the upstream falls over ------------------------------------------
GW[:upstream].set_down(true)
storm = Ractor.new(GW) do |gw|
  40.times.map { |i| gateway_call(gw, "monitor#{i % 8}", "storm-#{i}").first }.tally
end.value
abort "breaker never rejected fast: #{storm}" unless storm[:circuit_open]&.positive?
storm_hits = GW[:upstream].hits.count { |k, _| k.start_with?("storm-") }
abort "breaker let the storm through: #{storm_hits} upstream calls" if storm_hits > THRESHOLD + 3

GW[:upstream].set_down(false)
sleep COOLDOWN * 1.5
probe = gateway_call(GW, "prober", "probe-1")
abort "did not recover: #{probe}" unless probe.first == :ok

events = GW[:audit].events
abort "opened #{events.count(:breaker_opened)} times" unless events.count(:breaker_opened) >= 1
abort "never announced recovery" unless events.last == :breaker_closed
abort "breaker not closed: #{GW[:breaker].value}" unless GW[:breaker].value[:state] == :closed

puts "ok: greedy limited to #{g_tally[:ok]}/#{CAPACITY * 3}; 10 shared ids -> 10 upstream calls " \
     "for 60 requests; storm of 40 hit upstream #{storm_hits} times, breaker " \
     "#{events.tally.map { |e, n| "#{e} x#{n}" }.join(', ')}"
