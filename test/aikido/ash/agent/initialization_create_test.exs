defmodule Aikido.InitializationCreateTest.Hooks do
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.force_change_attribute(changeset, :observed, %{
        actor: context.actor,
        tenant: context.tenant,
        marker: get_in(changeset.context, [:shared, :marker])
      })
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      if get_in(changeset.context, [:shared, :reject]) == changeset.resource do
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(field: :count, message: "hook rejected")}
      else
        {:ok, %{record | count: record.count + Keyword.get(opts, :increment, 1)}}
      end
    end)
  end
end

defmodule Aikido.InitializationCreateTest.Slice do
  use Aikido.Slice, authorizers: [Ash.Policy.Authorizer]

  slice do
    name "initialization_create_slice"
    initialize {Aikido.InitializationCreateTest.Hooks, increment: 2}

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 4
        allow_nil? false
      end

      attribute :observed, :map do
        description "Caller context or runtime value captured by the receiving reducer."
        default %{}
      end
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:slice_allowed, true)
    end
  end
end

defmodule Aikido.InitializationCreateTest.Agent do
  use Aikido.Agent,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "initialization_create_agent"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 2
        allow_nil? false
      end

      attribute :observed, :map do
        description "Caller context or runtime value captured by the receiving reducer."
        default %{}
      end
    end

    slice :mounted, Aikido.InitializationCreateTest.Slice
  end

  changes do
    change Aikido.InitializationCreateTest.Hooks, on: [:create]
  end

  policies do
    policy action(:initialize) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end
  end
end

defmodule Aikido.InitializationCreateTest do
  use ExUnit.Case, async: false

  alias Aikido.InitializationCreateTest.Agent, as: Resource
  alias Aikido.InitializationCreateTest.Slice
  alias AikidoTest.Support.TestTracer

  test "native create hooks receive caller scope without inserting an independent resource row" do
    start_supervised!(TestTracer)
    actor = %{id: "initializer", slice_allowed: true}

    assert {:ok, agent} =
             Resource.initialize(
               %{state: %{mounted: %{count: "7", ignored: true}}},
               actor: actor,
               tenant: "tenant",
               context: %{shared: %{marker: "application context"}},
               tracer: TestTracer
             )

    assert agent.state.state.count == 3
    assert agent.state.mounted.count == 9
    observed = %{actor: actor, tenant: "tenant", marker: "application context"}
    assert agent.state.state.observed == observed
    assert agent.state.mounted.observed == observed

    query = Ash.DataLayer.resource_to_query(Resource, Aikido.RuntimeDomain)
    assert {:ok, []} = Ash.DataLayer.run_query(query, Resource)

    create_names =
      for {:metadata, _, :action, %{action: action}} <- TestTracer.get_spans(),
          action in [:__aikido_initialize_state__, :create],
          do: action

    assert length(create_names) == 2
  end

  test "configured initialization applies to creation without changing update behavior" do
    actor = %{slice_allowed: true}
    record = Ash.create!(Slice, %{}, actor: actor)
    assert record.count == 6
    updated = Ash.update!(record, %{count: "11"}, actor: actor)
    assert updated.count == 11
  end

  test "own-state and mounted create actions retain their separate authorization boundaries" do
    assert {:error, %Ash.Error.Forbidden{}} = Resource.initialize(%{})

    assert {:error, %Ash.Error.Forbidden{}} =
             Resource.initialize(%{}, actor: %{id: "initializer"})

    assert {:ok, _} = Resource.initialize(%{}, authorize?: false)
  end

  test "native after-action failures retain the owning state path" do
    for {resource, path} <- [{Resource, :state}, {Slice, :mounted}] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Resource.initialize(%{},
                 actor: %{slice_allowed: true},
                 context: %{shared: %{reject: resource}}
               )

      assert Enum.any?(errors, &(&1.path == [path] && &1.message == "hook rejected"))
    end
  end

  test "native casting failures retain paths and flat own-state inputs remain supported" do
    assert {:ok, agent} =
             Resource.initialize(%{state: %{count: "9", ignored: true}}, authorize?: false)

    assert agent.state.state.count == 10
    assert agent.state.mounted.count == 6

    for {state, path} <- [
          {%{state: %{count: "invalid"}}, :state},
          {%{mounted: %{count: "invalid"}}, :mounted}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Resource.initialize(%{state: state}, authorize?: false)

      assert Enum.any?(errors, &(&1.path == [path]))
    end
  end
end
