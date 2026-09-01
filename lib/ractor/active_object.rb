# frozen_string_literal: true

require_relative "active_object/future"

class Ractor
  # Active Object pattern on Ractors: each instance's state lives in its own
  # owner Ractor. `Foo.new` returns a proxy that publishes only the methods
  # declared with sync/async/future; they are executed on the owner one at a
  # time. See README.md.
  class ActiveObject
    class Error < ::Ractor::Error; end

    POLICIES = %i[sync async future].freeze

    DEF_NAME = /\A(?:[[:alpha:]_][[:alnum:]_]*[?!=]?|[+\-*\/%&|^<>~!`]|\*\*|[=!]=|<=|>=|<=>|===|=~|!~|<<|>>|\[\]=?|[+\-]@)\z/
    private_constant :DEF_NAME

    # Shared by proxies and servants: explicit *_send and the remote protocol.
    module Dispatch
      # The Ractor that owns the object's state.
      def owner = @__ao_owner__

      # True when called from the owner Ractor.
      def owner? = Ractor.current.equal?(@__ao_owner__)

      def sync_send(name, *args, **kwargs, &block)   = __ao_call__(:sync, name.to_sym, args, kwargs, block)
      def async_send(name, *args, **kwargs, &block)  = __ao_call__(:async, name.to_sym, args, kwargs, block)
      def future_send(name, *args, **kwargs, &block) = __ao_call__(:future, name.to_sym, args, kwargs, block)

      private

      def __ao_call__(policy, name, args, kwargs, block)
        return __ao_remote__(policy, name, args, kwargs, block) unless Ractor.current.equal?(@__ao_owner__)

        servant = Ractor[:__ao_servant__]
        case policy
        when :sync  then servant.__send__(name, *args, **kwargs, &block)
        when :async then servant.__send__(name, *args, **kwargs, &block); nil
        when :future
          begin
            Future.__ao_fulfilled__(servant.__send__(name, *args, **kwargs, &block))
          rescue Exception => e
            Future.__ao_rejected__(e)
          end
        end
      end

      def __ao_remote__(policy, name, args, kwargs, block)
        port = @__ao_port__
        raise Error, "#{self.class} instance was not created by .new (no owner Ractor)" unless port
        raise ArgumentError, "block is not supported for remote invocation (#{name})" if block

        case policy
        when :sync
          status, payload, backtrace = ActiveObject.__ao_sync_call__ do |reply|
            __ao_post__(port, [:sync, reply, name, args, kwargs])
          end
          raise ActiveObject.__ao_restore_exception__(payload, backtrace) if status == :raise
          payload
        when :async
          __ao_post__(port, [:async, nil, name, args, kwargs])
          nil
        when :future
          reply = Ractor::Port.new
          __ao_post__(port, [:future, reply, name, args, kwargs])
          Future.new(reply)
        else
          raise ArgumentError, "unknown invocation policy: #{policy.inspect}"
        end
      end

      def __ao_post__(port, request)
        port << request
      rescue Ractor::ClosedError
        raise Error, "owner Ractor #{@__ao_owner__.inspect} terminated"
      end
    end

    # Base of the per-class proxy classes (Foo::Proxy). A proxy is frozen and
    # shareable and has one method per declared (published) method of Foo.
    class Proxy
      include Dispatch

      def initialize(owner, port)
        @__ao_owner__ = owner
        @__ao_port__ = port
      end

      # The Ractor::ActiveObject subclass this proxy stands for.
      def active_object_class = self.class.active_object_class

      def inspect = "#<#{self.class} owner=#{@__ao_owner__.inspect}>"

      class << self
        attr_reader :active_object_class

        def __ao_bind__(klass)
          @active_object_class = klass
          klass.const_set(:Proxy, self) # named Foo::Proxy
          self
        end
      end
    end

    include Dispatch

    @__ao_policies__ = {}.freeze
    @__ao_proxy_class__ = Proxy

    class << self
      # Creates the owner Ractor, runs +initialize+ there and returns a
      # shareable proxy which forwards declared methods to the owner.
      def new(*args, **kwargs, &block)
        raise ArgumentError, "#{self}.new does not accept a block (it cannot be sent to the owner Ractor)" if block

        boot = Ractor::Port.new
        owner = Ractor.new(self, args, kwargs, boot, name: "ActiveObject(#{self})") do |klass, a, kw, b|
          Ractor::ActiveObject.__ao_run__(klass, a, kw, b)
        end
        # Only here: the owner may die before it can answer (e.g. .allocate fails).
        src, (status, payload, backtrace) = Ractor.select(boot, owner)
        raise Error, "owner Ractor #{owner.inspect} terminated during initialization" if src.equal?(owner)
        raise __ao_restore_exception__(payload, backtrace) if status == :raise

        Ractor.make_shareable(proxy_class.new(owner, payload))
      end

      # Class of the proxies returned by .new (a subclass of ActiveObject::Proxy).
      def proxy_class = @__ao_proxy_class__

      # --- policy DSL -------------------------------------------------------

      # Publish already defined methods on the proxy with the given policy:
      #   sync def foo ... end
      #   async :bar, :baz
      def sync(*names)   = __ao_declare__(:sync, names)
      def async(*names)  = __ao_declare__(:async, names)
      def future(*names) = __ao_declare__(:future, names)

      # Policy of +name+ (:sync, :async or :future), or nil if not published.
      def invocation_policy(name)
        name = name.to_sym
        klass = self
        while klass
          table = klass.instance_variable_get(:@__ao_policies__)
          return table[name] if table&.key?(name)
          klass = klass.superclass
        end
        nil
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@__ao_policies__, {}.freeze)
        subclass.instance_variable_set(:@__ao_proxy_class__, Class.new(proxy_class).__ao_bind__(subclass))
      end

      # --- internals --------------------------------------------------------

      def __ao_declare__(policy, names)
        raise ArgumentError, "#{policy} requires method name(s), e.g. `#{policy} def foo; end`" if names.empty?
        raise TypeError, "#{self} is not a subclass of Ractor::ActiveObject" if equal?(Ractor::ActiveObject)

        names = names.flatten.map(&:to_sym)
        names.each do |n|
          unless method_defined?(n) || private_method_defined?(n)
            raise NameError.new("undefined method '#{n}' for class '#{self}'", n)
          end
          # The table is read from any Ractor, so replace it by a shareable copy.
          @__ao_policies__ = Ractor.make_shareable(@__ao_policies__.merge(n => policy))
          __ao_define_proxy_method__(n, policy)
        end
        names.size == 1 ? names[0] : names
      end
      private :__ao_declare__

      def __ao_define_proxy_method__(name, policy)
        proxy = proxy_class
        sym = name.inspect
        # A string def has no closure, so the method is callable from any Ractor.
        body = <<~RUBY
          if Ractor.current.equal?(@__ao_owner__)
            Ractor[:__ao_servant__].__send__(#{sym}, *args, **kwargs, &block)
          else
            __ao_remote__(#{policy.inspect}, #{sym}, args, kwargs, block)
          end
        RUBY
        proxy.remove_method(name) if proxy.method_defined?(name, false)
        if name.match?(DEF_NAME)
          proxy.class_eval("def #{name}(*args, **kwargs, &block)\n#{body}end", __FILE__, __LINE__)
        else
          proxy.class_eval("define_method(#{sym}, &Ractor.shareable_proc { |*args, **kwargs, &block|\n#{body}})", __FILE__, __LINE__)
        end
      end
      private :__ao_define_proxy_method__

      # Owner Ractor body: build the servant, run initialize, then serve requests.
      def __ao_run__(klass, args, kwargs, boot)
        port = Ractor::Port.new
        servant = klass.allocate
        servant.instance_variable_set(:@__ao_owner__, Ractor.current)
        servant.instance_variable_set(:@__ao_port__, port)
        Ractor[:__ao_servant__] = servant

        begin
          servant.__send__(:initialize, *args, **kwargs)
        rescue Exception => e
          __ao_reply__(boot, :raise, e)
          return
        end
        boot << [:ok, port]

        proxy = klass.proxy_class.new(Ractor.current, port).freeze
        pending = pending_name = nil
        begin
          loop do
            kind, reply, name, rargs, rkwargs = port.receive
            pending, pending_name = (kind == :async ? nil : reply), name
            begin
              result = servant.__send__(name, *rargs, **rkwargs)
            rescue Exception => e
              pending = nil
              if kind == :async
                __ao_async_exception__(servant, e, name)
              else
                __ao_reply__(reply, :raise, e)
              end
              next
            end
            pending = nil
            next if kind == :async
            result = proxy if result.equal?(servant) # returning self yields the proxy, not a copy
            __ao_reply__(reply, :ok, result)
          end
        ensure
          # Going down (e.g. the method killed this thread) with a request in
          # flight: its caller waits on the reply port only, so answer it.
          if pending
            __ao_reply__(pending, :raise, Error.new("owner Ractor terminated during #{klass}##{pending_name}"))
          end
        end
      end

      def __ao_async_exception__(servant, exc, name)
        servant.on_async_exception(exc, name)
      rescue Exception => e
        warn "#{servant.class}#on_async_exception raised #{e.class}: #{e.message}"
      end
      private :__ao_async_exception__

      # Send a result/exception back; values that cannot cross Ractors are
      # converted into an Error so the caller never hangs.
      def __ao_reply__(port, status, payload)
        if status == :raise
          port << [:raise, payload, payload.backtrace]
        else
          port << [:ok, payload]
        end
      rescue Ractor::ClosedError
        nil # caller gave up; nothing to do
      rescue StandardError => e
        msg = if status == :raise
                "#{payload.class}: #{payload.message} (exception could not be transferred: #{e.message})"
              else
                "return value could not be transferred: #{e.message}"
              end
        port << [:raise, Error.new(msg), (payload.backtrace if status == :raise)]
      end
      private :__ao_reply__

      # Round trip on a reply port taken from a Ractor-local pool; the block
      # sends the request. Waiting on the reply port alone (rather than also
      # watching the owner Ractor) keeps the call cheap; a dying owner answers
      # its in-flight request from __ao_run__, and later sends fail with
      # ClosedError. A port is private to the caller while in use, so
      # concurrent threads never mix replies; one whose wait was interrupted
      # may still get a reply later, so it is not returned to the pool.
      def __ao_sync_call__
        pool = Ractor.store_if_absent(:__ao_reply_ports__) { [] }
        reply = pool.pop || Ractor::Port.new # Array#pop/push are atomic under the GVL
        yield reply
        msg = reply.receive
        pool.push(reply)
        msg
      end

      # Backtraces are lost when exceptions cross Ractors; rebuild: owner frames, then caller frames.
      def __ao_restore_exception__(exc, backtrace)
        exc.set_backtrace(Array(backtrace) + caller(2))
        exc
      end
    end

    # Called on the owner Ractor when an +async+ invocation raises.
    # Override to supervise; the default only reports it.
    def on_async_exception(exception, method_name)
      lines = ["#{self.class}##{method_name} (async) raised #{exception.class}: #{exception.message}"]
      lines.concat(Array(exception.backtrace).map { |l| "\tfrom #{l}" })
      warn lines.join("\n")
    end
  end
end
