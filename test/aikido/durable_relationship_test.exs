defmodule AikidoTest.DurableRelationshipTest do
  use ExUnit.Case, async: false
  import AikidoTest.Eventually
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
    %{instance: instance, pool: Aikido.durable_supervisor_name(instance), directory: directory}
  end

  test "adopted parent bindings are saved without PIDs and restored on activation", %{
    instance: instance,
    pool: pool
  } do
    {:ok, parent} = Aikido.start_agent(instance, Minimal, id: "parent")
    {:ok, child} = Aikido.start_agent(instance, Minimal, id: "child")
    assert {:ok, ^child} = AgentServer.adopt_child(parent, child, :worker, %{role: "analysis"})

    {key, _entry} =
      Enum.find(DurableServer.Supervisor.global_members(pool), fn {_key, {pid, _metadata}} ->
        pid == child
      end)

    assert :ok = Aikido.stop_agent(instance, child)
    assert {:ok, %{parent_id: "parent", tag: :worker}} = Aikido.parent_binding(instance, "child")

    {:ok, info} = DurableServer.Supervisor.get_server_info(pool, key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    refute Map.has_key?(saved.parent, :pid)
    assert saved.parent.meta == %{role: "analysis"}

    {:ok, restored} = Aikido.start_agent(instance, Minimal, id: "child")

    assert {:ok, %{id: "parent", pid: ^parent, tag: :worker}} =
             AgentServer.state(restored, &{:ok, &1.parent})
  end

  test "detachment is authoritative after recovery and cannot resurrect the startup parent", %{
    instance: instance
  } do
    {:ok, parent} = Aikido.start_agent(instance, Minimal, id: "parent")

    {:ok, child} =
      Aikido.start_agent(instance, Minimal,
        id: "child",
        on_parent_death: :continue,
        parent: %{pid: parent, id: "parent", tag: :worker}
      )

    assert :ok = Aikido.stop_agent(instance, parent)

    assert :orphan =
             await_state_value(child, fn runtime -> if is_nil(runtime.parent), do: :orphan end)

    assert :error = Aikido.parent_binding(instance, "child")
    assert :ok = Aikido.stop_agent(instance, child)
    {:ok, _parent} = Aikido.start_agent(instance, Minimal, id: "parent")
    {:ok, restored} = Aikido.start_agent(instance, Minimal, id: "child")
    assert {:ok, nil} = AgentServer.state(restored, &{:ok, &1.parent})
  end

  test "parent bindings survive a complete instance restart", %{
    instance: instance,
    directory: directory
  } do
    {:ok, parent} = Aikido.start_agent(instance, Minimal, id: "parent")
    {:ok, child} = Aikido.start_agent(instance, Minimal, id: "child")
    assert {:ok, ^child} = AgentServer.adopt_child(parent, child, :worker)
    assert :ok = Aikido.stop_agent(instance, child)
    assert :ok = Aikido.stop_agent(instance, parent)
    stop_supervised!(instance)

    start_supervised!({Aikido, name: instance, durable: [data_dir: directory]})
    assert {:ok, %{parent_id: "parent", tag: :worker}} = Aikido.parent_binding(instance, "child")
    assert nil == Aikido.whereis(instance, "child")
    {:ok, restored_parent} = Aikido.start_agent(instance, Minimal, id: "parent")
    {:ok, restored_child} = Aikido.start_agent(instance, Minimal, id: "child")
    refute restored_parent == parent
    refute restored_child == child

    assert {:ok, %{id: "parent", pid: ^restored_parent, tag: :worker}} =
             AgentServer.state(restored_child, &{:ok, &1.parent})
  end

  test "SpawnAgent children use DurableServer and recover their relationship after a crash", %{
    instance: instance,
    pool: pool
  } do
    {:ok, parent} = Aikido.start_agent(instance, Minimal, id: "parent")
    {:ok, runtime} = AgentServer.state(parent, &{:ok, &1})
    signal = Jido.Signal.new!("spawn.test", %{})
    directive = Aikido.Directives.spawn_agent(Minimal, :worker, opts: %{id: "child"})
    assert :ok = Aikido.Directive.exec(directive, signal, runtime)
    assert {:ok, child} = AgentServer.await_child(parent, :worker)
    assert {:ok, ^child} = Aikido.Durable.lookup(pool, "child")
    Process.exit(child, :kill)

    restored =
      eventually(
        fn ->
          case Aikido.whereis(instance, "child") do
            pid when is_pid(pid) and pid != child -> pid
            _ -> false
          end
        end,
        timeout: 10_000
      )

    assert {:ok, %{id: "parent", pid: ^parent}} = AgentServer.state(restored, &{:ok, &1.parent})
    assert {:ok, %{parent_id: "parent"}} = Aikido.parent_binding(instance, "child")
  end
end
