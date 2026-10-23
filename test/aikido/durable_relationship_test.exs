defmodule AikidoTest.DurableRelationshipTest do
  use ExUnit.Case, async: false
  import AikidoTest.AgentWait

  alias Aikido.AgentServer
  alias AikidoTest.TestAgents.Minimal

  setup do
    instance = __MODULE__.Instance

    directory =
      Path.join(System.tmp_dir!(), "aikido-relationships-#{System.unique_integer([:positive])}")

    start_supervised!(
      {Aikido,
       name: instance,
       durable: [
         data_dir: directory,
         durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
       ]}
    )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{instance: instance, durable: Aikido.durable_supervisor_name(instance), directory: directory}
  end

  test "adopted parent bindings are saved without PIDs and restored on activation", %{
    instance: instance,
    durable: durable
  } do
    {:ok, parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "parent")
    {:ok, child} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "child")
    assert {:ok, ^child} = AgentServer.adopt_child(parent, child, :worker, %{role: "analysis"})

    {key, _entry} =
      Enum.find(DurableServer.Supervisor.global_members(durable), fn {_key, {pid, _metadata}} ->
        pid == child
      end)

    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), child)

    assert {:ok, %{parent_id: "parent", tag: :worker}} =
             Aikido.Durable.parent_binding(Aikido.durable_supervisor_name(instance), "child")

    {:ok, info} = DurableServer.Supervisor.get_server_info(durable, key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    refute Map.has_key?(saved.parent, :pid)
    assert saved.parent.meta == %{role: "analysis"}

    {:ok, restored} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "child")

    assert {:ok, %{id: "parent", pid: ^parent, tag: :worker}} =
             AgentServer.state(restored, &{:ok, &1.parent})
  end

  test "detachment is authoritative after recovery and cannot resurrect the startup parent", %{
    instance: instance
  } do
    {:ok, parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "parent")

    {:ok, child} =
      AikidoTest.Case.start_test_agent(instance, Minimal,
        id: "child",
        on_parent_death: :continue,
        parent: %{pid: parent, id: "parent", tag: :worker}
      )

    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), parent)

    assert :orphan =
             await_state_value(child, fn runtime -> if is_nil(runtime.parent), do: :orphan end)

    assert :error =
             Aikido.Durable.parent_binding(Aikido.durable_supervisor_name(instance), "child")

    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), child)
    {:ok, _parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "parent")
    {:ok, restored} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "child")
    assert {:ok, nil} = AgentServer.state(restored, &{:ok, &1.parent})
  end

  test "restoring a child without its parent honors stop policy and retains the logical binding",
       %{
         instance: instance,
         durable: durable
       } do
    {:ok, parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "missing-parent")

    {:ok, child} =
      AikidoTest.Case.start_test_agent(instance, Minimal,
        id: "missing-parent/worker",
        on_parent_death: :stop,
        parent: %{pid: parent, id: "missing-parent", tag: :worker}
      )

    assert :ok = Aikido.Durable.stop(durable, child)
    assert :ok = Aikido.Durable.stop(durable, parent)

    {:ok, restored} = Aikido.Durable.start(durable, "missing-parent/worker", agent: Minimal)
    ref = Process.monitor(restored)
    assert_receive {:DOWN, ^ref, :process, ^restored, _}, 5000
    assert :error = Aikido.Durable.lookup(durable, "missing-parent/worker")

    assert {:ok, %{parent_id: "missing-parent"}} =
             Aikido.Durable.parent_binding(durable, "missing-parent/worker")

    {:ok, parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "missing-parent")

    {:ok, child} =
      AikidoTest.Case.start_test_agent(instance, Minimal, id: "missing-parent/worker")

    assert {:ok, %{pid: ^parent}} = AgentServer.state(child, &{:ok, &1.parent})
  end

  test "parent bindings survive a complete instance restart", %{
    instance: instance,
    directory: directory
  } do
    {:ok, parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "parent")
    {:ok, child} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "child")
    assert {:ok, ^child} = AgentServer.adopt_child(parent, child, :worker)
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), child)
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), parent)
    stop_supervised!(instance)

    start_supervised!({Aikido, name: instance, durable: [data_dir: directory]})

    assert {:ok, %{parent_id: "parent", tag: :worker}} =
             Aikido.Durable.parent_binding(Aikido.durable_supervisor_name(instance), "child")

    assert nil == AikidoTest.Case.agent_pid(instance, "child")
    {:ok, restored_parent} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "parent")
    {:ok, restored_child} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "child")
    refute restored_parent == parent
    refute restored_child == child

    assert {:ok, %{id: "parent", pid: ^restored_parent, tag: :worker}} =
             AgentServer.state(restored_child, &{:ok, &1.parent})
  end

  test "SpawnAgent children use DurableServer and recover their relationship after a crash", %{
    instance: instance,
    durable: durable
  } do
    {:ok, parent} =
      AikidoTest.Case.start_test_agent(instance, Minimal,
        id: "parent",
        sync: %{mode: :automatic, interval_ms: 1_234}
      )

    {:ok, runtime} = AgentServer.state(parent, &{:ok, &1})
    signal = Aikido.Signal.new!("spawn.test", %{})
    directive = Aikido.Directives.spawn_agent(Minimal, :worker, opts: %{id: "child"})
    assert :ok = Aikido.Directive.exec(directive, signal, runtime)
    assert {:ok, child} = AgentServer.await_child(parent, :worker)
    assert {:ok, ^child} = Aikido.Durable.lookup(durable, "child")
    assert %DurableServer{auto_sync: true, sync_every_ms: 1_234} = :sys.get_state(child)
    restored = AikidoTest.LifecycleWait.crash_and_await_replacement(child)

    assert {:ok, %{id: "parent", pid: ^parent}} = AgentServer.state(restored, &{:ok, &1.parent})

    assert {:ok, %{parent_id: "parent"}} =
             Aikido.Durable.parent_binding(Aikido.durable_supervisor_name(instance), "child")
  end

  test "restored team metadata resolves the same partition as its parent", %{
    instance: instance,
    durable: durable
  } do
    {:ok, default_team} = AikidoTest.Case.start_test_agent(instance, Minimal, id: "team")

    {:ok, blue_team} =
      AikidoTest.Case.start_test_agent(instance, Minimal, id: "team", partition: :blue)

    {:ok, parent} =
      AikidoTest.Case.start_test_agent(instance, Minimal, id: "owner", partition: :blue)

    {:ok, child} =
      AikidoTest.Case.start_test_agent(instance, Minimal,
        id: "member",
        partition: :blue,
        parent: %{
          pid: parent,
          id: "owner",
          partition: :blue,
          tag: :member,
          meta: %{team_id: "team", team_resource: Minimal, team_pid: blue_team, member: :member}
        }
      )

    assert :ok = Aikido.Durable.stop(durable, child)

    {:ok, restored} =
      AikidoTest.Case.start_test_agent(instance, Minimal, id: "member", partition: :blue)

    assert {:ok, %{pid: ^parent, meta: %{team_pid: ^blue_team}}} =
             AgentServer.state(restored, &{:ok, &1.parent})

    refute blue_team == default_team
  end
end
