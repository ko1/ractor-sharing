# frozen_string_literal: true

require_relative "active_object"

class Ractor
  # A Hash kept by a Ractor of its own. Reading it is a question you ask; every
  # change is work you send, and the work runs where the Hash is.
  #
  #   h = Ractor::ActorHash.new
  #   h.increment(:hits)                  # send it and carry on
  #   h[:hits]                            # ask
  #   h.async_call {|h| (h[:log] ||= []) << line }
  #
  # Because the entries never leave that Ractor except as copies, they do not
  # have to be shareable the way Ractor::LockHash's do: a value can be an Array
  # you go on appending to.
  class ActorHash < ActiveObject
    def initialize(initial = nil)
      @h = initial.nil? ? {} : initial.to_hash.dup
    end

    # Sent and not waited for: the arguments travel as arguments, so unlike a
    # block they can be anything, reassigned locals included.
    async def set(key, value)
      @h[key] = value
    end

    async def increment(key, by = 1)
      @h[key] = (@h[key] || 0) + by
    end

    sync def [](key) = @h[key]
    sync def key?(key) = @h.key?(key)
    sync def keys = @h.keys
    sync def to_h = @h.dup

    # Not published, so they stay off the proxy's API; the proxy reaches them
    # with sync_send, which gets at any method the way __send__ does.

    # [found, value]; keeps a stored nil apart from a missing key.
    def __lookup__(key) = @h.key?(key) ? [true, @h[key]] : [false, nil]

    # Runs the block on the owner, handing it the real Hash -- not a copy and
    # not a proxy. It cannot escape: the block runs here, and a return value is
    # copied on its way back, so what the caller gets is never this Hash.
    #
    # The proc arrives as a plain argument, not as a block: blocks cannot cross
    # Ractors, isolated procs can.
    def __call__(prc, args) = prc.call(@h, *args)

    # The caller-side half. These live on the proxy because that is what
    # ActiveObject hands out.
    class Proxy
      # Which Ractor keeps it is nobody's business out here.
      undef_method :owner, :owner?

      # Sends the block to the owner and carries on. Returns nil. An exception
      # reaches the owner's #on_async_exception.
      #
      #   h.async_call {|h| h[:hits] += 1 }
      #   h.async_call(line) {|h, line| h[:log] << line }
      #
      # The block must be isolatable: it may read outer variables that are never
      # reassigned, and anything else has to be passed as an argument.
      def async_call(*args, &block) = async_send(:__call__, isolate(block), args)

      # Sends the block and waits, returning what it returned, copied back.
      def call(*args, &block) = sync_send(:__call__, isolate(block), args)

      # Sends the block and returns a Future straight away.
      def future_call(*args, &block) = future_send(:__call__, isolate(block), args)

      def fetch(key, *default, &block)
        raise ArgumentError, "wrong number of arguments (given #{default.size + 1}, expected 1..2)" if default.size > 1

        found, value = sync_send(:__lookup__, key)
        return value if found
        return block.call(key) if block   # Hash#fetch prefers the block too
        return default.first if default.size == 1

        raise KeyError.new("key not found: #{key.inspect}", key: key, receiver: self)
      end

      def inspect = "#<#{active_object_class} #{to_h.inspect}>"

      private

      # A block that is already shareable is already isolated; making another one
      # allocates a Proc on every call, which on a hot path is most of the cost.
      def isolate(block)
        raise LocalJumpError, "no block given (yield)" unless block
        return block if Ractor.shareable?(block)

        Ractor.shareable_proc(&block)
      end
    end
  end
end
