defmodule AikidoTest.AshPersistence.Permanent do
  use Ash.Resource,
    domain: AikidoTest.AshPersistence.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "permanent"
    instance AikidoTest.AshPersistence.Instance

    schema do
      attribute :value, :integer do
        description "Domain value used to verify state transitions and native contracts."
        default 0
        public? true
      end
    end
  end
end

defmodule AikidoTest.AshPersistence.Temporary do
  use Ash.Resource,
    domain: AikidoTest.AshPersistence.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "temporary"
    instance AikidoTest.AshPersistence.Instance
    persistence :temporary

    schema do
      attribute :value, :integer do
        description "Domain value used to verify state transitions and native contracts."
        default 0
        public? true
      end
    end
  end
end

defmodule AikidoTest.AshPersistence.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension], validate_config_inclusion?: false

  agents do
    agent :permanent, AikidoTest.AshPersistence.Permanent
    agent :temporary, AikidoTest.AshPersistence.Temporary
  end
end

defmodule AikidoTest.AshPersistenceTest do
  use ExUnit.Case, async: false

  alias AikidoTest.AshPersistence.{Domain, Permanent}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "aikido-retention-#{System.unique_integer([:positive])}")

    instance = AikidoTest.AshPersistence.Instance

    start_supervised!(
      {Aikido,
       name: instance,
       durable: [
         data_dir: directory,
         durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
       ]}
    )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{durable: Aikido.durable_supervisor_name(instance), instance: instance}
  end

  test "permanent is the default and stop preserves saved state" do
    ref = Domain.permanent_start!(%{id: "saved", value: 7})
    assert {:ok, %{status: :stopped}} = Domain.permanent_stop(ref)

    restarted = Domain.permanent_start!(%{id: "saved", value: 99})
    assert %{value: 7} = Domain.permanent_inspect!(restarted)
  end

  test "temporary stop deletes the snapshot and restarting creates fresh state" do
    ref = Domain.temporary_start!(%{id: "scratch", value: 7})
    assert {:ok, %{status: :stopped}} = Domain.temporary_stop(ref.pid)
    assert {:error, _} = Domain.temporary_delete(ref.id)

    restarted = Domain.temporary_start!(%{id: "scratch", value: 99})
    assert %{value: 99} = Domain.temporary_inspect!(restarted)
  end

  test "delete removes a stopped permanent agent without activating it" do
    ref = Domain.permanent_start!(%{id: "old", value: 7})
    Domain.permanent_stop!(ref)
    assert {:ok, %{id: "old", status: :deleted}} = Domain.permanent_delete(ref.id)

    restarted = Domain.permanent_start!(%{id: "old", value: 99})
    assert %{value: 99} = Domain.permanent_inspect!(restarted)
  end

  test "delete terminates a running agent and discards its saved state" do
    ref = Domain.permanent_start!(%{id: "live", value: 7})
    monitor = Process.monitor(ref.pid)
    assert {:ok, %{status: :deleted}} = Domain.permanent_delete(ref)
    assert_receive {:DOWN, ^monitor, :process, _, _}

    restarted = Domain.permanent_start!(%{id: "live", value: 99})
    assert %{value: 99} = Domain.permanent_inspect!(restarted)
  end

  test "delete cannot remove a different resource's snapshot" do
    ref = Domain.permanent_start!(%{id: "owned", value: 7})
    assert {:error, _} = Domain.temporary_delete(ref.id)
    assert %{value: 7} = Domain.permanent_inspect!(ref)

    Domain.permanent_stop!(ref)
    assert {:error, _} = Domain.temporary_delete(ref.id)
    restarted = Domain.permanent_start!(%{id: "owned"})
    assert %{value: 7} = Domain.permanent_inspect!(restarted)
  end

  test "low-level and durable stop honour the temporary resource's retention", %{
    instance: instance,
    durable: durable
  } do
    ref = Domain.temporary_start!(%{id: "low-level", value: 7})
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), ref.pid)
    restarted = Domain.temporary_start!(%{id: "low-level", value: 8})
    assert %{value: 8} = Domain.temporary_inspect!(restarted)

    assert :ok = Aikido.Durable.stop(durable, restarted.id)
    fresh = Domain.temporary_start!(%{id: "low-level", value: 9})
    assert %{value: 9} = Domain.temporary_inspect!(fresh)
  end

  test "temporary agents retain crash recovery until explicitly stopped" do
    ref = Domain.temporary_start!(%{id: "recoverable", value: 7})
    recovered = AikidoTest.LifecycleWait.crash_and_await_replacement(ref.pid)

    assert %{value: 7} = Domain.temporary_inspect!(recovered)
  end

  test "a temporary agent's own stop signal also deletes its saved state" do
    ref = Domain.temporary_start!(%{id: "self-stop", value: 7})
    monitor = Process.monitor(ref.pid)
    assert :ok = Aikido.AgentServer.cast(ref.pid, Aikido.Signal.new!("aikido.agent.stop", %{}))
    assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000

    restarted = Domain.temporary_start!(%{id: "self-stop", value: 99})
    assert %{value: 99} = Domain.temporary_inspect!(restarted)
  end

  test "deleting a partitioned PID does not delete the default partition", %{durable: durable} do
    main = Domain.permanent_start!(%{id: "partitioned", value: 1})

    alpha =
      Domain.permanent_start!(%{id: "partitioned", value: 2},
        context: %{aikido_runtime_options: [partition: :alpha]}
      )

    assert {:ok, %{status: :deleted}} = Domain.permanent_delete(alpha.pid)
    assert %{value: 1} = Domain.permanent_inspect!(main)

    assert {:ok, fresh} =
             Aikido.Durable.ensure_started(durable, "partitioned",
               agent: Permanent,
               partition: :alpha,
               initial_state: %{state: %{value: 3}}
             )

    assert %{value: 3} = Domain.permanent_inspect!(fresh)
  end

  test "deletion clears the saved parent binding", %{instance: instance} do
    parent = Domain.permanent_start!(%{id: "parent"})
    child = Domain.permanent_start!(%{id: "child"})
    binding = Aikido.Ownership.ParentRef.new!(%{pid: parent.pid, id: parent.id, tag: :child})
    assert {:ok, _} = Aikido.AgentServer.adopt_parent(child.pid, binding)

    assert {:ok, _} =
             Aikido.Durable.parent_binding(Aikido.durable_supervisor_name(instance), child.id)

    Domain.permanent_stop!(child)
    Domain.permanent_delete!(child.id)

    assert :error =
             Aikido.Durable.parent_binding(Aikido.durable_supervisor_name(instance), child.id)
  end

  test "explicit delete handles reference inputs and malformed identifiers" do
    ref = Domain.temporary_start!(%{id: "reference"})
    assert %{status: :deleted} = Domain.temporary_delete!(ref)
    assert {:error, _} = Domain.temporary_delete(123)
    assert {:error, _} = Domain.permanent_delete("missing")
  end
end
