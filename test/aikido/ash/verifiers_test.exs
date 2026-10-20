defmodule AikidoTest.AshVerifiersTest do
  use ExUnit.Case, async: false

  test "AI requires an agent host" do
    output = compile_resource([Aikido.Ash.AI], "ai do max_iterations 2 end")
    assert output =~ "AI requires Aikido.Ash.Agent"
  end

  test "slices require the embedded data layer" do
    output =
      compile_resource(
        [Aikido.Ash.Slice],
        """
        attributes do
          uuid_primary_key :id do
            description "Unique identity for the resource used by the verifier fixture."
          end
        end

        slice do
          name "not_embedded"
        end
        """,
        embedded?: false
      )

    assert output =~ "Aikido.Ash.Slice requires data_layer: :embedded"
  end

  test "slice routes and schedules require reducer action contracts" do
    for declaration <- [~s(route "invalid.run", :invalid), ~s(schedule "* * * * *", :invalid)] do
      output =
        compile_resource(
          [Aikido.Ash.Slice],
          """
          slice do
            name "invalid_reducer"
            #{if String.starts_with?(declaration, "route"), do: declaration}
          end

          #{if String.starts_with?(declaration, "schedule"), do: "schedules do #{declaration} end"}

          actions do
            action :invalid, :map do
              run AikidoTest.TestActions.Actions.ClearState
            end
          end
          """,
          embedded?: true
        )

      assert output =~ "Slice routes require generic Ash actions with a :state argument"
    end
  end

  test "public agent signals require concrete types" do
    output =
      compile_resource([Aikido.Ash.Agent], """
      agent do
        name "wildcard"
        signal :increment, "counter.*", {AikidoTest.AshFixtures.CounterSlice, :increment}
      end
      """)

    assert output =~ "Public signals require a concrete type"
  end

  test "duplicate public signal names are checked before declarations are lost" do
    output =
      compile_resource([Aikido.Ash.Agent], """
      agent do
        name "duplicate_signals"
        signal :increment, "counter.one", {AikidoTest.AshFixtures.CounterSlice, :increment}
        signal :increment, "counter.two", {AikidoTest.AshFixtures.CounterSlice, :increment}
      end
      """)

    assert output =~ "Got duplicate Aikido.Ash.Agent.Signal: increment"
  end

  test "attributes cannot shadow the agent state path" do
    output =
      compile_resource([Aikido.Ash.Agent], """
      agent do
        name "shadowed_state"
        schema do
          attribute :state, :integer do
            description "Reserved state field used to verify schema shadowing is rejected."
            default 0
          end
        end
      end
      """)

    assert output =~ "Resource attributes cannot collide with the agent state path"
  end

  test "middleware behaviour validation uses Spark after compilation" do
    output =
      compile_resource([Aikido.Ash.Agent], """
      agent do
        name "invalid_middleware"
        middleware [String]
      end
      """)

    assert output =~ "middleware"
    assert output =~ "Aikido.Middleware"
  end

  test "team topology is reserved for startup configuration" do
    output =
      compile_resource([Aikido.Ash.Agent, Aikido.Ash.Team], """
      agent do
        name "reserved_topology"
        schema do
          attribute :topology, :map do
            description "Team topology supplied when the fixture starts."
            default %{}
          end
        end
      end

      team do
      end
      """)

    assert output =~ "Team resources reserve :topology"
  end

  test "identity cannot be used as the agent state path" do
    output =
      compile_resource([Aikido.Ash.Agent], """
      agent do
        name "reserved_identity"
        path :id
      end
      """)

    assert output =~ "The :id attribute is reserved for the agent identity"
  end

  test "Ash enforces uniqueness across schema and resource attributes" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        compile_resource([Aikido.Ash.Agent], """
        agent do
          name "duplicate_fields"
          schema do
            attribute :count, :integer do
              description "Current counter value updated by routed signals."
              default 0
            end
          end
        end

        attributes do
          attribute :count, :integer do
            description "Current counter value updated by routed signals."
            default 1
          end
        end
        """)
      end

    assert error.message =~ "fields"
    assert error.message =~ "count"
  end

  test "domains reject resources without the agent extension" do
    module = Module.concat(__MODULE__, "Domain#{System.unique_integer([:positive])}")

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Ash.Domain, extensions: [Aikido.Ash.Domain], validate_config_inclusion?: false

          agents do
            agent :slice, AikidoTest.AshFixtures.CounterSlice
          end
        end
        """)
      end)

    assert output =~ "Domain agents must use the Aikido.Ash.Agent extension"
  end

  defp compile_resource(extensions, body, opts \\ []) do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")
    layer = if opts[:embedded?], do: ":embedded", else: "Ash.DataLayer.Simple"

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: #{layer},
          extensions: #{inspect(extensions)}

        #{body}
      end
      """)
    end)
  end
end
