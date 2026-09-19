module Steep
  module AST
    module Types
      # A type RBS cannot spell.
      #
      # `FiniteSet`, `MetaClass` and `MethodObject` are all exact where a
      # signature can only be general — the members of a set, the module a
      # singleton class is of, the method a reflection names — and a signature
      # is where each of them stops. `back_type` is what it is written AS at
      # that boundary, and every boundary asks for it through this module rather
      # than naming the three: `Factory#type_1` on the way into RBS, subtyping
      # on the way to a nominal question, the specialization sidecar on the way
      # to disk.
      #
      # The sidecar is why this is a contract and not a convention. It records a
      # return as `type.to_s` and reads it back through `RBS::Parser.parse_type`,
      # and none of these three parses back to itself — `method(::Foo#bar)`
      # parses as the ALIAS `method`, silently, which is a wrong type rather
      # than a missing one.
      module NotInRBS
      end
    end
  end
end
