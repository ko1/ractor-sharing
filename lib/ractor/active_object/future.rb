# frozen_string_literal: true

class Ractor
  class ActiveObject
    # Result handle returned by +future+ invocations.
    #
    # Only the Ractor that issued the invocation may call #value / #wait,
    # because the underlying reply port belongs to that Ractor.
    class Future
      def initialize(port)
        @port = port
        @mutex = Mutex.new
        @state = :pending # :pending | :fulfilled | :rejected
        @result = nil
      end

      # Pre-resolved futures, used when the caller is already the owner.
      def self.__ao_fulfilled__(value) = new(nil).tap { |f| f.__ao_settle__(:fulfilled, value) }
      def self.__ao_rejected__(exc)    = new(nil).tap { |f| f.__ao_settle__(:rejected, exc) }

      # Waits for completion. Returns self; never raises for a rejected future.
      def wait
        @mutex.synchronize do
          if @state == :pending
            status, payload, backtrace = @port.receive
            @port = nil
            if status == :ok
              __ao_settle__(:fulfilled, payload)
            else
              __ao_settle__(:rejected, ActiveObject.__ao_restore_exception__(payload, backtrace))
            end
          end
        end
        self
      end

      # Waits for completion and returns the method's return value, or
      # re-raises the exception the method raised on the owner Ractor.
      def value
        wait
        raise @result if @state == :rejected
        @result
      end

      # True once #wait / #value has observed the result. Does not poll.
      def resolved? = @state != :pending

      def rejected? = @state == :rejected

      def __ao_settle__(state, result)
        @state = state
        @result = result
      end

      def inspect = "#<#{self.class} #{@state}>"
    end
  end
end
