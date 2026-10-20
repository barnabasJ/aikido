defmodule Aikido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest do
  use ExUnit.Case, async: false

  test "reports when AikidoTest.Fixtures.OtherCollidingSectionExtension is mounted alongside a slice that also picks `:shared_section`" do
    output = ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule Aikido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest.CollidingHost do
        use Aikido.Agent,
          extensions: [AikidoTest.Fixtures.OtherCollidingSectionExtension, AikidoTest.Fixtures.CollidingSectionExtension],
          default_slices: false

        agent do
          name "colliding_host"
        end

        slices do
          slice :shared_section, AikidoTest.Fixtures.OtherCollidingSectionExtension
          slice :other_section, AikidoTest.Fixtures.CollidingSectionExtension
        end
      end
      """)
    end)

    assert output =~ ~r/Section name collisions.*:shared_section/s
  end

  test "mounting just AikidoTest.Fixtures.OtherCollidingSectionExtension compiles cleanly" do
    Code.compile_string("""
    defmodule Aikido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest.SingleExtensionHost do
      use Aikido.Agent,
        extensions: [AikidoTest.Fixtures.OtherCollidingSectionExtension],
        default_slices: false

      agent do
        name "single_extension_host"
      end

      slices do
        slice :shared_section, AikidoTest.Fixtures.OtherCollidingSectionExtension
      end
    end
    """)

    assert Code.ensure_loaded?(
             Aikido.Dsl.Agent.Transformers.WalkExtensionsSectionCollisionTest.SingleExtensionHost
           )
  end
end
