# frozen_string_literal: true

require_relative "active_object"

class Ractor
  # A Hash kept by a Ractor of its own.
  #
  #   h = Ractor::ActorHash.new
  #   h[:a] = 1
  #   h.call {|db| db[:log] ||= []; db[:log] << :x }
  #
  # Values never leave that Ractor except as copies, so unlike Ractor::LockHash
  # they do not have to be shareable: a value can be a Hash or an Array you go
  # on mutating, as long as you mutate it inside #call, where the block runs on
  # the owner.
  #
  # Reading or writing one entry is one message and atomic by itself. Anything
  # that reads and then writes belongs in one #call.
  class ActorHash < ActiveObject
    def initialize(initial = nil)
      @h = initial.nil? ? {} : initial.to_hash.dup
    end

    sync def [](key) = @h[key]
    sync def []=(key, value)
      @h[key] = value
    end
    sync def delete(key) = @h.delete(key)
    sync def clear = (@h.clear; nil)
    sync def key?(key) = @h.key?(key)
    sync def size = @h.size
    sync def empty? = @h.empty?
    sync def keys = @h.keys
    sync def to_h = @h.dup

    # [found, value]; keeps a stored nil apart from a missing key.
    sync def __lookup__(key) = @h.key?(key) ? [true, @h[key]] : [false, nil]

    # Runs the block on the owner. The proc arrives as a plain argument, not as
    # a block: blocks cannot cross Ractors, isolated procs can.
    sync def __call__(prc, args) = prc.call(@h, *args)

    # The caller-side half. These live on the proxy because that is what
    # ActiveObject hands out, and only published methods reach the owner.
    class Proxy
      # Runs the block on the owner Ractor, with the Hash itself as its first
      # argument, and returns what the block returned (copied back).
      #
      #   h.call {|db| db[:hits] += 1 }
      #   h.call(k, v) {|db, k, v| db[k] = v }
      #
      # The block must be isolatable: it may read outer variables that are never
      # reassigned, and anything else has to be passed as an argument.
      def call(*args, &block) = sync_send(:__call__, isolate(block), args)

      # Same, but does not wait: returns nil, and an exception is reported by
      # the owner's #on_async_exception.
      def async_call(*args, &block) = async_send(:__call__, isolate(block), args)

      # Same, but returns a Future straight away.
      def future_call(*args, &block) = future_send(:__call__, isolate(block), args)

      def fetch(key, *default, &block)
        found, value = sync_send(:__lookup__, key)
        return value if found
        return default.first if default.size == 1
        return block.call(key) if block
        raise KeyError.new("key not found: #{key.inspect}", key: key, receiver: self)
      end

      def inspect = "#<#{active_object_class} #{to_h.inspect}>"

      private

      def isolate(block)
        raise LocalJumpError, "no block given (yield)" unless block
        Ractor.shareable_proc(&block)
      end
    end
  end
end
