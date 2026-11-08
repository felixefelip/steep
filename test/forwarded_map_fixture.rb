module ForwardedMapFixture
  MUTEX = <<~RUBY
    class Thread::Mutex
      def synchronize
        raise ThreadError, "must be called with a block" unless block_given?

        lock
        begin
          yield
        ensure
          unlock
        end
      end
    end
  RUBY

  BACKEND = <<~RUBY
    class MBackend
      def initialize(options = nil, &default_proc)
        set_backend(default_proc)
        @default_proc = default_proc
      end

      def [](key)
        @backend[key]
      end

      def []=(key, value)
        @backend[key] = value
      end

      private

      def set_backend(default_proc)
        if default_proc
          @backend = ::Hash.new { |_h, key| default_proc.call(self, key) }
        else
          @backend = {}
        end
      end
    end

    class MLocked < MBackend
      def initialize(options = nil, &default_proc)
        super(options, &default_proc)
        @write_lock = Mutex.new
      end

      def []=(key, value)
        @write_lock.synchronize { super }
      end
    end
  RUBY

  RBS = <<~RBS
    class MBackend
      @backend: Hash[untyped, untyped]
      @default_proc: untyped
      def initialize: (?untyped options) ?{ (untyped, untyped) -> untyped } -> void
      def []: (untyped key) -> untyped
      def []=: (untyped key, untyped value) -> untyped
      private
      def set_backend: (untyped default_proc) -> untyped
    end
    class MLocked < MBackend
      @write_lock: Thread::Mutex
      def initialize: (?untyped options) ?{ (untyped, untyped) -> untyped } -> void
      def []=: (untyped key, untyped value) -> untyped
    end
    class MMap[K, V] < MLocked
      def []: (K key) -> V?
      def []=: (K key, V value) -> V
    end
    class MUse
      self.@memo: MMap[untyped, untyped]
      def self.read: () -> untyped
    end
  RBS
end
