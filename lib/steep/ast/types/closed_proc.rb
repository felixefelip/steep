module Steep
  module AST
    module Types
      # A proc made from a closed block (`ObjectStates::Yields.closed_params`),
      # which remembers the block:
      #
      #   def self.outer(key, &block) = inner(block, key)   # block: proc(&{…}) under `outer(:a) { |k| k.to_s }`
      #   inner(->(key) { key.to_s }, :a)                   # the lambda: proc(&{…})
      #
      # A closed block computes the same wherever it runs, so a `call` on it is
      # the block's body checked with what is passed. It answers everything
      # else as the `Proc` it is, and the sidecar writes it as one (`plain`).
      class ClosedProc < Proc
        attr_reader :source

        def initialize(type:, block:, self_type:, source:)
          super(type: type, block: block, self_type: self_type)
          @source = source
        end

        def self.of(proc, source)
          new(type: proc.type, block: proc.block, self_type: proc.self_type, source: source)
        end

        def ==(other)
          other.is_a?(ClosedProc) && other.digest == digest && plain == other.plain
        end

        alias eql? ==

        def hash
          plain.hash ^ digest.hash
        end

        def subst(s)
          ClosedProc.of(plain.subst(s), source)
        end

        def map_type(&block)
          ClosedProc.of(plain.map_type(&block), source)
        end

        def digest
          @digest ||= ObjectStates::Yields.digest(source)
        end

        def to_s
          "proc(&{#{digest}})"
        end

        def plain
          Proc.new(type: type, block: block, self_type: self_type)
        end
      end
    end
  end
end
