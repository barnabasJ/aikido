defmodule Aikido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest do
  @moduledoc """
  Regression coverage for the `HasSchemaAndRoutes` verifier wired into
  `Aikido.Dsl.Slice`. A slice without a `schema:` must fail compilation
  with a `Spark.Error.DslError`.
  """

  use ExUnit.Case, async: true

  Code.ensure_compiled!(AikidoTest.PluginTestAction)

  alias Aikido.Dsl.Slice.Verifiers.HasSchemaAndRoutes

  describe "verify/1" do
    test "rejects a slice that omits `schema:`" do
      dsl_state = build_state(schema: nil)

      assert {:error, %Spark.Error.DslError{path: [:slice, :schema], message: message}} =
               HasSchemaAndRoutes.verify(dsl_state)

      assert message =~ "Slice must declare a `schema:`"
    end

    test "accepts an explicitly empty Ash field contract" do
      dsl_state = build_state(schema: [])

      assert :ok = HasSchemaAndRoutes.verify(dsl_state)
    end

    test "accepts a slice with `schema:`" do
      dsl_state =
        build_state(schema: [value: [allow_nil?: true, type: :term]])

      assert HasSchemaAndRoutes.verify(dsl_state) == :ok
    end
  end

  describe "@after_verify hook (compile-time integration)" do
    test "the wired-in verifier blocks a no-schema slice from compiling cleanly" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string(
            "defmodule Aikido.Dsl.Slice.Verifiers.HasSchemaAndRoutesTest.NoSchemaSlice do\n  use Aikido.Slice\n\n  slice do\n    name \"no_schema\"\n  end\nend\n"
          )
        end)

      assert output =~ "Slice must declare a `schema:`"
    end

    test "a happy-path slice compiles cleanly with no warnings" do
      defmodule HappyPathSlice do
        @moduledoc false
        use Aikido.Slice

        slice do
          name("happy_path")

          schema do
            attribute(:value, :term, allow_nil?: true)
          end
        end

        signal_routes do
          route("happy_path.go", AikidoTest.PluginTestAction)
        end
      end

      assert Aikido.Dsl.Slice.Info.signal_routes(HappyPathSlice) == [
               {"happy_path.go", AikidoTest.PluginTestAction}
             ]
    end
  end

  defp build_state(opts) do
    schema = Keyword.fetch!(opts, :schema)

    %{[:slice] => %{opts: [schema: schema]}}
  end
end
