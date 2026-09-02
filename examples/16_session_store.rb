# frozen_string_literal: true
#
# A session store with "log out everywhere" -- the LockHash shape as it
# actually occurs in a web backend. Two directions live in one hash:
#
#   "sid:..."  => user          the session token a request authenticates with
#   "user:..." => [sids]        the index that makes logout-all possible
#
# Login writes both directions; logout-all deletes N sessions AND the index.
# Each is one synchronize, because the gap matters: revoke sessions one by one
# and a racing request can still authenticate with a not-yet-deleted token
# while the account believes it logged out. The auditor checks the two
# directions agree in every snapshot it ever takes.
#
#   ruby -Ilib examples/16_session_store.rb
Warning[:experimental] = false
require "ractor/sharing"

STORE = Ractor::LockHash.new

def login(store, user, device)
  sid = "sid:#{user}:#{device}"
  store.synchronize do |h|
    h[sid] = user
    h["user:#{user}"] = (h["user:#{user}"] || []) + [sid]
  end
  sid
end

def authenticate(store, sid) = store[sid]

def logout_everywhere(store, user)
  store.synchronize do |h|
    (h["user:#{user}"] || []).each { |sid| h.delete(sid) }
    h.delete("user:#{user}")
  end
end

workers = %w[ann ben cho dee].map do |user|
  Ractor.new(STORE, user) do |store, me|
    authed = 0
    5.times do |round|
      sids = 4.times.map { |d| login(store, me, "device#{round}-#{d}") }
      sids.each { |sid| authed += 1 if authenticate(store, sid) == me }
      logout_everywhere(store, me)
      abort "a token survived logout-all" if sids.any? { |sid| authenticate(store, sid) }
    end
    authed
  end
end

# The auditor never catches the store between the two directions: every session
# it sees is listed in its user's index, and every listed session exists.
auditor = Ractor.new(STORE) do |store|
  400.times.count do
    snap = store.to_h
    snap.each do |k, v|
      next unless k.start_with?("sid:")
      abort "session #{k} not in its index" unless (snap["user:#{v}"] || []).include?(k)
    end
    snap.each do |k, sids|
      next unless k.start_with?("user:")
      sids.each { |sid| abort "index lists a dead session #{sid}" unless snap.key?(sid) }
    end
    true
  end
end

audits = auditor.value
authed = workers.sum(&:value)
abort "sessions leaked: #{STORE.to_h}" unless STORE.to_h.empty?
abort "logins failed to authenticate" unless authed == 4 * 5 * 4
puts "ok: #{authed} authentications, 20 logout-everywheres, store empty at the end; " \
     "#{audits} audits and the two directions never disagreed"
