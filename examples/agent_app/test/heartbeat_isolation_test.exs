defmodule AgentExamples.HeartbeatIsolationTest do
  use ExUnit.Case, async: false

  test "native heartbeat writes continue while an agent-data writer is suspended" do
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    config = DurableServer.Supervisor.__get_config__(pool)
    assert config.storage_backend.state.name == AgentExamples.Store
    assert config.heartbeat_backend.state.name == AgentExamples.HeartbeatStore
    assert EKV.Supervisor.get_config(AgentExamples.HeartbeatStore).num_shards == 1

    agent = AgentExamples.Agents.counter_start!()
    on_exit(fn -> AgentExamples.Agents.counter_stop(agent) end)
    writer = Process.whereis(EKV.Replica.shard_name(AgentExamples.Store, 0))
    :ok = :sys.suspend(writer)

    try do
      assert {:ok, _} =
               DurableServer.StorageBackend.put_object(
                 config.heartbeat_backend,
                 config.prefix <> "heartbeat-isolation-probe",
                 %{observed_at: System.system_time(:millisecond)},
                 timeout: 1000
               )
    after
      :ok = :sys.resume(writer)
    end

    assert :ok =
             DurableServer.StorageBackend.delete_object(
               config.heartbeat_backend,
               config.prefix <> "heartbeat-isolation-probe"
             )

    AgentExamples.Agents.counter_add!(agent, %{amount: 2})
    assert AgentExamples.Agents.counter_inspect!(agent.id).count == 2
    metrics = DurableServer.LifecycleManager.get_heartbeat_metrics(pool)
    assert metrics.deadline_ms == 28_000
  end
end
