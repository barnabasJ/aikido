defmodule Aikido.Dsl.ExtensionTest do
  use ExUnit.Case, async: true

  describe "DSL section schema validation" do
    test "valid memory block compiles cleanly when extensions: registers the host section" do
      Code.compile_string("""
      defmodule Aikido.Dsl.ExtensionTest.HostValidMemory do
        use Aikido.Agent,
          extensions: [Aikido.Slices.Memory],
          default_slices: false

        agent do
          name "host_valid_memory"
        end

        slices do
          slice :short_term, Aikido.Slices.Memory
        end
      end
      """)

      assert Code.ensure_loaded?(Aikido.Dsl.ExtensionTest.HostValidMemory)
    end
  end
end
