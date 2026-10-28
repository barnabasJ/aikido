defmodule AgentExamples.ScopeAdapterTest do
  @moduledoc "Native lifecycle checks for the playground browser scope boundary."
  use ExUnit.Case, async: false

  alias AgentExamples.{CheckpointCounter, Counter, DurableScope, Team}

  test "native team startup signs the same bounded playground scope for its root and children" do
    actor = %{id: Ash.UUIDv7.generate()}
    scope = [actor: actor, tenant: "playground"]
    team = command!(Team, :start, %{id: Ash.UUIDv7.generate()}, scope)
    cleanup(Team, team.id, scope)
    assert_authenticated_snapshot(team.pid, actor)

    current = command!(Team, :inspect, %{agent: team}, scope)
    assert %{counter: counter, notebook: notebook, worker: worker} = current.team.members

    for child <- [counter, notebook, worker] do
      assert Process.alive?(child)
      assert_authenticated_snapshot(child, actor)
    end

    command!(Counter, :add, %{agent: counter, amount: 3}, scope)
    assert %{count: 13} = command!(Counter, :inspect, %{agent: counter}, scope)
  end

  test "a permanent example restores its signed scope and state through native public lifecycle" do
    actor = %{id: Ash.UUIDv7.generate()}
    scope = [actor: actor, tenant: "playground"]
    id = Ash.UUIDv7.generate()
    agent = command!(CheckpointCounter, :start, %{id: id}, scope)
    cleanup(CheckpointCounter, id, scope)
    command!(CheckpointCounter, :add, %{agent: agent, amount: 7}, scope)
    assert_authenticated_snapshot(agent.pid, actor)
    command!(CheckpointCounter, :stop, %{agent: agent}, scope)

    restored = command!(CheckpointCounter, :start, %{id: id}, scope)
    refute restored.pid == agent.pid
    assert %{count: 7} = command!(CheckpointCounter, :inspect, %{agent: restored}, scope)
    assert_authenticated_snapshot(restored.pid, actor)
  end

  test "a signed credential cannot be forged or replayed under any changed claim identity" do
    actor = %{id: Ash.UUIDv7.generate()}
    scope = [actor: actor, tenant: "playground"]
    agent = command!(Counter, :start, %{id: Ash.UUIDv7.generate()}, scope)
    cleanup(Counter, agent.id, scope)
    saved = snapshot(agent.pid)
    identity = Aikido.Durable.ScopeAdapter.identity(saved.options)
    assert is_binary(saved.credential)

    assert {:error, :invalid_playground_credential} =
             DurableScope.restore(saved.credential <> "tampered", saved.agent, identity)

    for {key, value} <- [
          agent_module: AgentExamples.Worker,
          id: "another-agent",
          aikido: AgentExamples.OtherRuntime,
          partition: :another_partition,
          durable_server: AgentExamples.OtherPool,
          durable_key: "another-agent"
        ] do
      assert {:error, :invalid_playground_credential} =
               DurableScope.restore(saved.credential, saved.agent, Map.put(identity, key, value))
    end

    assert_authenticated_snapshot(agent.pid, actor)
  end

  test "the demo boundary rejects extra actor authority, foreign tenants and application context" do
    actor = %{id: Ash.UUIDv7.generate()}
    scope = [actor: actor, tenant: "playground"]
    agent = command!(Counter, :start, %{id: Ash.UUIDv7.generate()}, scope)
    cleanup(Counter, agent.id, scope)
    saved = snapshot(agent.pid)
    identity = Aikido.Durable.ScopeAdapter.identity(saved.options)

    for unsupported <- [
          [actor: Map.put(actor, :admin?, true), tenant: "playground"],
          [actor: actor, tenant: "another-tenant"],
          [actor: actor, tenant: "playground", context: %{actor: %{id: "another-owner"}}],
          [actor: actor, tenant: "playground", authorize?: false]
        ] do
      assert {:error, :unsupported_playground_scope} =
               DurableScope.prepare(%{}, unsupported, identity)
    end
  end

  defp assert_authenticated_snapshot(pid, actor) do
    saved = snapshot(pid)
    identity = Aikido.Durable.ScopeAdapter.identity(saved.options)

    assert {:ok, restored_scope} = DurableScope.restore(saved.credential, saved.agent, identity)
    assert restored_scope.actor == actor
    assert restored_scope.tenant == "playground"
    assert restored_scope.context == %{}
    assert restored_scope.authorize?
    assert {:agent, _agent} = saved.agent
    refute Keyword.has_key?(saved.options, :initialization_options)
  end

  defp snapshot(pid) do
    :sys.get_state(pid).user_state
    |> Aikido.Durable.AgentServer.dump_state()
    |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))
  end

  defp command!(resource, action, arguments, scope) do
    resource
    |> Ash.ActionInput.for_action(action, arguments, scope)
    |> Ash.run_action!()
  end

  defp cleanup(resource, id, scope) do
    on_exit(fn ->
      resource
      |> Ash.ActionInput.for_action(:stop, %{agent: id}, scope)
      |> Ash.run_action()

      pool = Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource))
      Aikido.Durable.delete(pool, id, agent: resource)
    end)
  end
end
