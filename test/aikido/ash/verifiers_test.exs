defmodule AikidoTest.AshVerifiersTest do
  use ExUnit.Case, async: false

  test "AI requires an agent host" do
    output = compile_resource([Aikido.AI.Extension], "ai do max_iterations 2 end")
    assert output =~ "AI requires Aikido.Agent.Extension"
  end

  test "slices require the embedded data layer" do
    output =
      compile_resource(
        [Aikido.Slice.Extension],
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

    assert output =~ "Aikido.Slice.Extension requires data_layer: :embedded"
  end

  test "slice routes and schedules require reducer action contracts" do
    for declaration <- [~s(route "invalid.run", :invalid), ~s(schedule "* * * * *", :invalid)] do
      output =
        compile_resource(
          [Aikido.Slice.Extension],
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

  test "explicitly public agent routes require concrete types" do
    output =
      compile_resource([Aikido.Agent.Extension], """
      agent do
        name "wildcard"
        route "counter.*", {AikidoTest.AshFixtures.CounterSlice, :increment}, name: :increment, public?: true
      end
      """)

    assert output =~ "Public routes require a concrete type"
  end

  test "explicitly public wildcard slice routes are rejected" do
    output =
      compile_resource(
        [Aikido.Slice.Extension],
        """
        slice do
          name "wildcard"
          route "counter.**", {AikidoTest.AshFixtures.CounterSlice, :increment}, public?: true
        end
        """,
        embedded?: true
      )

    assert output =~ "Public routes require a concrete type"
  end

  test "duplicate public route names are checked before declarations are lost" do
    output =
      compile_resource([Aikido.Agent.Extension], """
      agent do
        name "duplicate_signals"
        route "counter.one", {AikidoTest.AshFixtures.CounterSlice, :increment}, name: :increment
        route "counter.two", {AikidoTest.AshFixtures.CounterSlice, :increment}, name: :increment
      end
      """)

    assert output =~ "Public route names must be unique: :increment"
  end

  test "attributes cannot shadow the agent state path" do
    output =
      compile_resource([Aikido.Agent.Extension], """
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
      compile_resource([Aikido.Agent.Extension], """
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
      compile_resource([Aikido.Agent.Extension, Aikido.Team.Extension], """
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
      compile_resource([Aikido.Agent.Extension], """
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
        compile_resource([Aikido.Agent.Extension], """
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
          use Ash.Domain, extensions: [Aikido.Domain.Extension], validate_config_inclusion?: false

          agents do
            agent :slice, AikidoTest.AshFixtures.CounterSlice
          end
        end
        """)
      end)

    assert output =~ "Domain agents must use the Aikido.Agent.Extension extension"
  end

  test "team reconciled inheritance is opt-in and preserves native route ownership" do
    for declaration <- ["", "reconcile_inherit [:storage_id, :storage_replay?]"] do
      module = Module.concat(__MODULE__, "InheritedTeam#{System.unique_integer([:positive])}")

      output =
        compile_resource(
          [Aikido.Agent.Extension, Aikido.Team.Extension],
          inherited_team_body(declaration),
          module: module
        )

      assert output == ""
      expected = if declaration == "", do: [], else: [:storage_id, :storage_replay?]
      assert Aikido.Agent.Info.team_config(module).reconcile_inherit == expected

      routes = Aikido.Agent.Info.signal_routes(module) ++ Aikido.Agent.Info.routes(module)
      router = Aikido.Signal.Router.new!(routes)

      assert {:ok, [own, cascade]} =
               Aikido.Signal.Router.route(router, %{type: "aikido.agent.inherit"})

      paths = Aikido.Agent.Info.slice_paths_for_action(module)
      assert paths[own] == [:state]
      assert paths[cascade] == [:team]

      admission = Spark.Dsl.Extension.get_persisted(module, :aikido_public_admission_routes, [])

      assert Enum.any?(admission, fn route ->
               route.type == "aikido.agent.inherit" && route.name == :adopt_inherited &&
                 route.public? && route.action == own
             end)

      refute Enum.any?(admission, fn route ->
               route.type == "aikido.agent.inherit" && route.public? && route.action == cascade
             end)
    end
  end

  test "team reconciled inheritance rejects attributes outside its creation contract" do
    output =
      compile_resource(
        [Aikido.Agent.Extension, Aikido.Team.Extension],
        inherited_team_body("reconcile_inherit [:other]")
      )

    assert output =~ "reconcile_inherit fields must also be declared in inherit"
  end

  test "team reconciled inheritance rejects missing attributes and mounted state" do
    for field <- [:missing, :todos] do
      output =
        compile_resource(
          [Aikido.Agent.Extension, Aikido.Team.Extension],
          inherited_team_body("reconcile_inherit [#{inspect(field)}]")
        )

      assert output =~ "reconcile_inherit requires an own-state attribute"
    end
  end

  test "team reconciled inheritance rejects sensitive and identity attributes" do
    for field <- [
          :secret,
          :actor_id,
          :org_id,
          :thread_id,
          :principal_id,
          :definition_ref,
          :execution_credential
        ] do
      output =
        compile_resource(
          [Aikido.Agent.Extension, Aikido.Team.Extension],
          inherited_team_body("reconcile_inherit [#{inspect(field)}]")
        )

      assert output =~ "reconcile_inherit cannot change identity or sensitive fields"
    end
  end

  defp inherited_team_body(reconciliation) do
    """
    agent do
      name "inherited_configuration"
      slice :todos, Aikido.Todo.Slice

      schema do
        attribute :storage_id, :string do
          description "Shared storage configuration inherited by this team's members."
        end

        attribute :storage_replay?, :boolean do
          description "Whether members retain journal facts for their storage consumer."
          default false
        end

        attribute :secret, :string do
          description "Sensitive application data excluded from inherited reconciliation."
          sensitive? true
        end

        attribute :actor_id, :string do
          description "Execution identity excluded from inherited reconciliation."
        end

        attribute :org_id, :string do
          description "Known immutable execution binding excluded even without a sensitive flag."
        end

        attribute :thread_id, :string do
          description "Known immutable execution binding excluded even without a sensitive flag."
        end

        attribute :principal_id, :string do
          description "Known immutable execution binding excluded even without a sensitive flag."
        end

        attribute :definition_ref, :string do
          description "Known immutable execution binding excluded even without a sensitive flag."
        end

        attribute :execution_credential, :string do
          description "Known immutable execution binding excluded even without a sensitive flag."
        end

        attribute :other, :string do
          description "Own-state configuration not selected for creation inheritance."
        end
      end
    end

    team do
      inherit [:storage_id, :storage_replay?, :secret, :actor_id, :org_id, :thread_id, :principal_id, :definition_ref, :execution_credential, :missing, :todos]
      #{reconciliation}
    end
    """
  end

  defp compile_resource(extensions, body, opts \\ []) do
    module =
      opts[:module] || Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")

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
