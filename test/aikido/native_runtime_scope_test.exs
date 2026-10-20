defmodule Aikido.NativeRuntimeScopeTest.Create do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _, context) do
    observed = %{
      actor_id: context.actor && context.actor.id,
      tenant: context.tenant,
      marker: changeset.context[:marker],
      shared: changeset.context[:shared] && changeset.context.shared[:shared_marker],
      authorize?: context.authorize?,
      tracers: List.wrap(context.tracer)
    }

    changeset
    |> Ash.Changeset.force_change_attribute(:created, observed)
    |> Ash.Changeset.after_action(fn changeset, record ->
      if observer = get_in(changeset.context, [:shared, :observer]),
        do: send(observer, {:native_create, changeset.resource, observed})

      {:ok, record}
    end)
  end
end

defmodule Aikido.NativeRuntimeScopeTest.Slice do
  use Aikido.Slice, authorizers: [Ash.Policy.Authorizer]

  slice do
    name "runtime_scope_slice"

    schema do
      attribute :created, :map, default: %{}
    end
  end

  changes do
    change Aikido.NativeRuntimeScopeTest.Create, on: [:create]
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.NativeRuntimeScopeTest.Capture do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, context) do
    runtime = input.context.aikido

    observed = %{
      actor_id: context.actor && context.actor.id,
      tenant: context.tenant,
      marker: input.context[:marker],
      shared: input.context[:shared] && input.context.shared[:shared_marker],
      authorize?: context.authorize?,
      tracers: List.wrap(context.tracer),
      agent_id: runtime.agent_id
    }

    directives =
      case runtime.signal.type do
        "scope.capture" ->
          [
            Aikido.Directives.async_task(fn ->
              %Aikido.Signal{
                id: "scope-result",
                time: "2026-01-01T00:00:00Z",
                type: "scope.result",
                source: "/test"
              }
            end)
          ]

        "scope.spawn" ->
          [Aikido.Directives.spawn_agent(Aikido.NativeRuntimeScopeTest.Resource, :child)]

        _ ->
          []
      end

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | observed: observed},
      directives: directives
    )
  end
end

defmodule Aikido.NativeRuntimeScopeTest.Calculation do
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, [field: field], context) do
    Enum.map(records, fn record ->
      case field do
        :actor -> record.owner_id == (context.actor && context.actor.id)
        :tenant -> record.workspace == context.tenant
      end
    end)
  end
end

defmodule Aikido.NativeRuntimeScopeTest.Resource do
  use Aikido.Agent, data_layer: Ash.DataLayer.Ets, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "native_runtime_scope"

    schema do
      attribute :created, :map, default: %{}
      attribute :observed, :map, default: %{}
      attribute :owner_id, :string
      attribute :workspace, :string
    end

    slice :mounted, Aikido.NativeRuntimeScopeTest.Slice
    signal :capture, "scope.capture", :reduce
    signal :observe, "scope.observe", :reduce
    signal :spawn, "scope.spawn", :reduce
    route "scope.result", :reduce
  end

  changes do
    change Aikido.NativeRuntimeScopeTest.Create, on: [:create]
  end

  calculations do
    calculate :owned, :boolean, {Aikido.NativeRuntimeScopeTest.Calculation, field: :actor}
    calculate :in_workspace, :boolean, {Aikido.NativeRuntimeScopeTest.Calculation, field: :tenant}
  end

  actions do
    read :read do
      primary? true
    end

    action :reduce, Aikido.Types.ActionResult do
      argument :state, :term
      run Aikido.NativeRuntimeScopeTest.Capture
    end
  end

  policies do
    policy action_type(:action) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.NativeRuntimeScopeTest.Team do
  use Aikido.Agent, extensions: [Aikido.Ash.Team]

  agent do
    name "native_scope_team"
  end

  team do
    member :member, Aikido.NativeRuntimeScopeTest.Resource
  end
end

defmodule Aikido.NativeRuntimeScopeTest do
  use ExUnit.Case, async: false
  alias Aikido.NativeRuntimeScopeTest.{Resource, Slice, Team}
  alias AikidoTest.Support.TestTracer

  setup do
    start_supervised!(TestTracer)
    start_supervised!({Aikido, durable: AikidoTest.Case.durable_options()})
    :ok
  end

  defp scope do
    [
      actor: %{id: "alice", allowed: true},
      tenant: "workspace",
      tracer: TestTracer,
      context: %{
        marker: "ordinary",
        credential: "never-persist",
        shared: %{shared_marker: "shared", observer: self()}
      }
    ]
  end

  defp action(resource, action, arguments, options \\ []) do
    resource |> Ash.ActionInput.for_action(action, arguments, options) |> Ash.run_action(options)
  end

  test "public commands preserve native application context and options through async results" do
    assert {:ok, ref} = action(Resource, :start, %{}, scope())

    assert {:ok, observed} =
             Aikido.AgentServer.call_until(
               ref.pid,
               fn -> action(Resource, :capture, %{agent: ref}, scope()) end,
               "scope.result",
               &{:ok, &1.agent.state.state.observed}
             )

    assert %{
             actor_id: "alice",
             tenant: "workspace",
             marker: "ordinary",
             shared: "shared",
             authorize?: true,
             tracers: [TestTracer]
           } = observed

    assert observed.agent_id == ref.id

    assert {:ok, _} = action(Resource, :observe, %{agent: ref}, actor: nil, authorize?: false)

    assert {:ok, %{actor_id: nil, tenant: nil, marker: nil, shared: nil, authorize?: false}} =
             Aikido.AgentServer.state(ref.pid, &{:ok, &1.agent.state.state.observed})

    assert Enum.any?(
             TestTracer.get_spans(),
             &match?({:start, _, {:custom, :aikido_async_task}, _}, &1)
           )
  end

  test "public startup runs scoped native creates without rows or persisted caller credentials" do
    id = Ash.UUIDv7.generate()
    assert {:error, _} = action(Resource, :start, %{id: id})
    assert :error = Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), id)
    assert {:ok, ref} = action(Resource, :start, %{id: id}, scope())
    assert_receive {:native_create, Resource, observed}
    assert_receive {:native_create, Slice, ^observed}

    assert %{
             actor_id: "alice",
             tenant: "workspace",
             marker: "ordinary",
             shared: "shared",
             authorize?: true,
             tracers: [TestTracer]
           } = observed

    query = Ash.DataLayer.resource_to_query(Resource, Aikido.RuntimeDomain)
    assert {:ok, []} = Ash.DataLayer.run_query(query, Resource)
    wrapper = :sys.get_state(ref.pid).user_state

    saved =
      wrapper
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(1, &1))

    refute Keyword.has_key?(saved.options, :initialization_options)
    refute inspect(saved, limit: :infinity) =~ "never-persist"

    assert {:ok, _} = action(Resource, :stop, %{agent: ref})
    assert {:ok, restored} = action(Resource, :start, %{id: ref.id})
    assert :ok = Aikido.AgentServer.await_ready(restored.pid)
    refute_receive {:native_create, _, _}

    assert {:ok, ^observed} =
             Aikido.AgentServer.state(restored.pid, &{:ok, &1.agent.state.state.created})

    assert {:ok, _} = action(Resource, :start, %{}, authorize?: false)
  end

  test "fallback initialization consumes transient native scope before strict options validation" do
    assert {:ok, state, {:continue, :post_init}} =
             Aikido.AgentServer.init(
               agent_module: Resource,
               id: "fallback",
               initialization_options: scope()
             )

    assert state.agent.state.state.created.actor_id == "alice"
    assert state.agent.state.mounted.created.marker == "ordinary"
    assert_receive {:native_create, Resource, _}
    assert_receive {:native_create, Slice, _}
  end

  test "spawn directives and team member startup retain native caller scope" do
    assert {:ok, parent} = action(Resource, :start, %{}, scope())
    assert_receive {:native_create, Resource, _}
    assert_receive {:native_create, Slice, _}
    assert {:ok, _} = action(Resource, :spawn, %{agent: parent}, scope())
    assert {:ok, child} = Aikido.AgentServer.await_child(parent.pid, :child)
    assert_receive {:native_create, Resource, %{actor_id: "alice", marker: "ordinary"}}
    assert_receive {:native_create, Slice, %{actor_id: "alice", marker: "ordinary"}}
    assert {:ok, pid} = Aikido.AgentServer.state(child, &{:ok, &1.parent.pid})
    assert pid == parent.pid

    assert {:ok, team} = action(Team, :start, %{}, scope())
    assert_receive {:native_create, Resource, %{actor_id: "alice", marker: "ordinary"}}
    assert_receive {:native_create, Slice, %{actor_id: "alice", marker: "ordinary"}}
    assert {:ok, member} = Aikido.AgentServer.await_child(team.pid, :member)

    assert {:ok, {"ordinary", "workspace"}} =
             Aikido.AgentServer.state(
               member,
               &{:ok, {&1.agent.state.state.created.marker, &1.agent.state.state.created.tenant}}
             )
  end

  test "public list passes actor and tenant to native calculated filtering" do
    assert {:ok, alice} =
             action(Resource, :start, %{owner_id: "alice", workspace: "one"}, scope())

    assert {:ok, bob} = action(Resource, :start, %{owner_id: "bob", workspace: "two"}, scope())

    assert {:ok, [first]} =
             action(Resource, :list, %{filter: [owned: true]}, actor: %{id: "alice"})

    assert first.id == alice.id

    assert {:ok, [second]} =
             action(Resource, :list, %{filter: [owned: true]}, actor: %{id: "bob"})

    assert second.id == bob.id

    assert {:ok, [tenant_match]} =
             action(Resource, :list, %{filter: [in_workspace: true]}, tenant: "two")

    assert tenant_match.id == bob.id

    assert {:ok, [scalar]} =
             action(Resource, :list, %{filter: [owner_id: "alice"], sort: [id: :desc], limit: 1})

    assert scalar.id == alice.id
  end
end
