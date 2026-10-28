defmodule AikidoTest.Agent.SnapshotTest.ObserveProjection do
  use Ash.Resource.Preparation

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def prepare(input, _, context) do
    if input.action.name == :__aikido_snapshot__ do
      send(
        input.context.observer,
        {:snapshot_projection, self(), context.actor, input.tenant, input.context.marker}
      )
    end

    input
  end
end

defmodule AikidoTest.Agent.SnapshotTest.RecordInitialization do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if observer = changeset.context[:observer] do
        send(observer, {:snapshot_fixture_created, changeset.resource})
      end

      {:ok, record}
    end)
  end
end

defmodule AikidoTest.Agent.SnapshotTest.Details do
  use Aikido.Slice

  slice do
    name "snapshot_details"

    schema do
      attribute :label, :string do
        description "Value retained on the mounted resource."
        default "mounted"
      end
    end
  end

  changes do
    change AikidoTest.Agent.SnapshotTest.RecordInitialization, on: [:create]
  end
end

defmodule AikidoTest.Agent.SnapshotTest.Resource do
  use Aikido.Agent,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "snapshot_resource"
    instance AikidoTest.Agent.SnapshotTest.Instance

    schema do
      attribute :value, :integer do
        description "Live value projected into the resource snapshot."
        default 3
      end

      attribute :readonly_label, :string do
        description "Read-only resource value initialized by its native default."
        writable? false
        default "readonly"
      end
    end

    slice :details, AikidoTest.Agent.SnapshotTest.Details
  end

  changes do
    change AikidoTest.Agent.SnapshotTest.RecordInitialization, on: [:create]
  end

  preparations do
    prepare AikidoTest.Agent.SnapshotTest.ObserveProjection, on: [:action]
  end

  actions do
    read :read do
      primary? true
    end
  end

  policies do
    policy action([
             :start,
             :initialize,
             :__aikido_initialize_state__,
             :__aikido_apply_state__,
             :inspect,
             :list,
             :read
           ]) do
      authorize_if actor_present()
    end
  end
end

defmodule AikidoTest.Agent.SnapshotTest do
  use ExUnit.Case, async: false

  alias AikidoTest.Agent.SnapshotTest.{Details, Resource}
  alias AikidoTest.Support.TestTracer

  setup do
    start_supervised!(TestTracer)

    start_supervised!(
      {Aikido,
       name: AikidoTest.Agent.SnapshotTest.Instance, durable: AikidoTest.Case.durable_options()}
    )

    :ok
  end

  test "inspect and list materialize native records without creating or persisting them" do
    options = [
      actor: %{id: "reader"},
      tenant: "workspace",
      context: %{observer: self(), marker: "application-context"},
      tracer: TestTracer
    ]

    reference = run_action!(Resource, :start, %{}, options)
    assert_receive {:snapshot_fixture_created, Resource}
    assert_receive {:snapshot_fixture_created, Details}

    inspected = run_action!(Resource, :inspect, %{agent: reference}, options)

    assert %Resource{value: 3, readonly_label: "readonly", details: %Details{label: "mounted"}} =
             inspected

    assert [listed] = run_action!(Resource, :list, %{}, options)
    assert listed.id == inspected.id
    assert listed.readonly_label == "readonly"
    assert listed.details == inspected.details
    caller = self()

    assert_receive {:snapshot_projection, ^caller, %{id: "reader"}, "workspace",
                    "application-context"}

    assert_receive {:snapshot_projection, ^caller, %{id: "reader"}, "workspace",
                    "application-context"}

    assert Ash.read!(Resource, actor: %{id: "reader"}) == []
    refute_receive {:snapshot_fixture_created, _}

    spans = TestTracer.get_spans()
    command_caller = self()

    projection_refs =
      for {:start, ref, :action, name} <- spans,
          String.ends_with?(name, ".__aikido_snapshot__"),
          Enum.any?(spans, &match?({:parent, ^ref, _, ^command_caller}, &1)),
          do: ref

    assert length(projection_refs) == 2

    for ref <- projection_refs do
      assert Enum.any?(spans, &match?({:parent, ^ref, _, ^command_caller}, &1))
    end

    # The implementation's private projection is deliberately not another
    # policy boundary: callers only need access to inspect/list.
    assert {:error, %Ash.Error.Forbidden{}} =
             Resource
             |> Ash.ActionInput.for_action(
               :__aikido_snapshot__,
               %{snapshot: Map.from_struct(inspected)},
               options
             )
             |> Ash.run_action(options)
  end

  defp run_action!(resource, action, arguments, options) do
    resource
    |> Ash.ActionInput.for_action(action, arguments, options)
    |> Ash.run_action!(options)
  end
end
