defmodule Aikido.Durable.LegacyCheckpointTest do
  use AikidoTest.Case, async: false
  alias AikidoTest.LegacyCheckpoint

  @fixture Path.expand("../../fixtures/legacy_checkpoint/6ad/opaque.json", __DIR__)
  @entries Path.expand("../../fixtures/legacy_checkpoint/6ad/opaque-entries.json", __DIR__)

  test "real older opaque checkpoint restores native defaults without replacing retained history" do
    start_runtime(LegacyCheckpoint.AnonymousAuthority)
    saved = load_fixture()
    {:checkpoint, %{agent: old}} = saved.agent
    refute Map.has_key?(old.state.thread, :generation)
    refute Map.has_key?(old.state.thread, :entry_receipts)
    expected = File.read!(@entries) |> Jason.decode!()
    {:ok, {pid, _metadata}} = activate_saved(saved)
    :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, restored} = Aikido.AgentServer.state(pid, &{:ok, &1.agent})
    assert restored.id == old.id
    assert restored.state.state.label == old.state.state.label
    assert restored.state.thread.entries == old.state.thread.entries
    assert is_binary(restored.state.thread.generation)
    assert restored.state.thread.entry_receipts == []
    assert Enum.map(restored.state.thread.entries, & &1.id) == Enum.map(expected, & &1["id"])
    assert Enum.map(restored.state.thread.entries, & &1.at) == [123, 456]
    generation = restored.state.thread.generation
    reference = %{id: restored.id, pid: pid, resource: LegacyCheckpoint.Opaque}

    LegacyCheckpoint.Domain.opaque_configure_replay!(reference, %{
      metadata: %{routing: %{writer: "fixture"}}
    })

    assert {:ok, opted_in} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.thread})
    assert opted_in.entries == old.state.thread.entries
    assert opted_in.generation == generation
    assert opted_in.next_sequence == 2
    LegacyCheckpoint.Domain.opaque_stop!(reference)
    restarted = LegacyCheckpoint.Domain.opaque_start!(%{id: restored.id})
    assert {:ok, again} = Aikido.AgentServer.state(restarted.pid, &{:ok, &1.agent.state.thread})
    assert again.generation == generation
    assert again.entries == old.state.thread.entries
  end

  test "explicit nil remains invalid instead of receiving a newly declared default" do
    start_runtime(LegacyCheckpoint.AnonymousAuthority)
    saved = load_fixture()
    {:checkpoint, checkpoint} = saved.agent

    # Deliberately malformed saved input tests the native rejection boundary.
    thread = Map.put(checkpoint.agent.state.thread, :generation, nil)
    agent = %{checkpoint.agent | state: Map.put(checkpoint.agent.state, :thread, thread)}
    saved = %{saved | agent: {:checkpoint, %{checkpoint | agent: agent}}}
    assert {:error, reason} = activate_saved(saved)
    assert inspect(reason) =~ "generation"

    assert :error =
             Aikido.Durable.lookup(
               Aikido.durable_supervisor_name(Aikido.Default),
               saved.options[:id]
             )
  end

  test "revoked native authority rejects an old checkpoint before initialization" do
    start_runtime(LegacyCheckpoint.RefusedAuthority)
    saved = load_fixture()
    assert {:error, reason} = activate_saved(saved)
    assert inspect(reason) =~ "revoked"

    assert :error =
             Aikido.Durable.lookup(
               Aikido.durable_supervisor_name(Aikido.Default),
               saved.options[:id]
             )
  end

  defp start_runtime(authority) do
    options = Keyword.put(durable_options(), :scope_adapter, authority)
    start_supervised!({Aikido, name: Aikido.Default, durable: options})
  end

  defp load_fixture do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> then(&Aikido.Durable.AgentServer.load_state(2, &1))
  end

  defp activate_saved(saved) do
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    key = Aikido.Durable.storage_key(saved.options[:id], saved.options[:partition])

    DurableServer.Supervisor.start_child(
      pool,
      {Aikido.Durable.AgentServer, key: key, initial_state: saved}
    )
  end
end
