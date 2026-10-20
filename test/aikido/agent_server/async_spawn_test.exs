defmodule AikidoTest.AgentServer.AsyncSpawnTest.Emit do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [input.arguments.directive]
    )
  end
end

defmodule AikidoTest.AgentServer.AsyncSpawnTest.Orphaned do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | orphan_count: state.orphan_count + 1})
  end
end

defmodule AikidoTest.AgentServer.AsyncSpawnTest.Harness do
  use Aikido.Agent

  agent do
    name "async_spawn_harness"

    schema do
      attribute :count, :integer, default: 42
    end

    route "test.spawn", :emit
    route "test.noop", {Aikido.AgentServer.RuntimeActions, :noop}
  end

  actions do
    action :emit, Aikido.Types.ActionResult do
      argument :state, :term
      argument :directive, :term, allow_nil?: false
      run AikidoTest.AgentServer.AsyncSpawnTest.Emit
    end
  end
end

defmodule AikidoTest.AgentServer.AsyncSpawnTest.SlowAgent do
  use Aikido.Agent

  agent do
    name "async_spawn_slow_agent"

    schema do
      attribute :observer, :term
      attribute :block?, :boolean, default: false
      attribute :orphan_count, :integer, default: 0
    end

    route "aikido.agent.orphaned", :orphaned
  end

  actions do
    action :orphaned, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServer.AsyncSpawnTest.Orphaned
    end
  end

  def externalize(%{block?: true, observer: observer} = state) do
    send(observer, {:activation_waiting, self()})

    receive do
      :release_activation -> %{state | block?: false}
    after
      5_000 -> raise "activation gate was not released"
    end
  end

  def externalize(state), do: state

  def reinstate(state) do
    if state.observer, do: send(state.observer, {:activation_initialized, self()})
    state
  end
end

defmodule AikidoTest.AgentServer.AsyncSpawnTest.ControlledChild do
  def start_link(observer) do
    send(observer, {:generic_start_waiting, self()})

    receive do
      :release_start ->
        Agent.start_link(fn ->
          send(observer, {:generic_started, self()})
          :ready
        end)
    after
      5_000 -> {:error, :gate_not_released}
    end
  end
end

defmodule AikidoTest.AgentServer.AsyncSpawnTest.IgnoredChild do
  def start_link(observer) do
    send(observer, :generic_ignored)
    :ignore
  end
end

defmodule AikidoTest.AgentServer.AsyncSpawnTest do
  use AikidoTest.Case, async: true

  test "generic child startup cannot block the owning agent and supports native :ignore",
       context do
    parent = start_server(context, __MODULE__.Harness)

    directive = %Aikido.Directives.Spawn{
      child_spec: %{
        id: :controlled,
        start: {__MODULE__.ControlledChild, :start_link, [self()]}
      }
    }

    assert {:ok, :accepted} = send_directive(parent, directive)
    assert_receive {:generic_start_waiting, starter}

    assert {:ok, %{count: 42}} =
             Aikido.AgentServer.call(parent, signal("test.noop"), &{:ok, &1.agent.state.state})

    send(starter, :release_start)
    assert_receive {:generic_started, child}
    assert Process.alive?(child)

    directive = %Aikido.Directives.Spawn{
      child_spec: %{id: :ignored, start: {__MODULE__.IgnoredChild, :start_link, [self()]}}
    }

    assert {:ok, :accepted} = send_directive(parent, directive)
    assert_receive :generic_ignored
    assert Process.alive?(parent)
  end

  test "term tags start tracked children without requiring a string protocol", context do
    parent = start_server(context, __MODULE__.Harness)
    assert {:ok, parent_id} = Aikido.AgentServer.state(parent, &{:ok, &1.id})

    for tag <- [{:worker, 1}, %{worker: 2}, [1, :not_a_character], :named, "text"] do
      directive = %Aikido.Directives.SpawnAgent{
        agent: __MODULE__.Harness,
        tag: tag,
        restart?: false
      }

      assert {:ok, :accepted} = send_directive(parent, directive)
      assert {:ok, child} = Aikido.AgentServer.await_child(parent, tag)

      assert {:ok, {child_id, ^tag, ^parent}} =
               Aikido.AgentServer.state(child, &{:ok, {&1.id, &1.parent.tag, &1.parent.pid}})

      if tag in [:named, "text"] do
        assert child_id == "#{parent_id}/#{tag}"
      else
        assert String.starts_with?(child_id, parent_id <> "/term:")
      end
    end

    tag = {:explicit, 3}

    directive = %Aikido.Directives.SpawnAgent{
      agent: __MODULE__.Harness,
      tag: tag,
      opts: %{id: "explicit-term-child"},
      restart?: false
    }

    assert {:ok, :accepted} = send_directive(parent, directive)
    assert {:ok, child} = Aikido.AgentServer.await_child(parent, tag)
    assert {:ok, "explicit-term-child"} = Aikido.AgentServer.state(child, &{:ok, &1.id})
  end

  test "agent startup is supervised work with the original agent as parent", context do
    parent = start_server(context, __MODULE__.Harness)
    assert {:ok, :accepted} = send_directive(parent, slow_directive(:stop))
    assert_receive {:activation_waiting, starter}

    assert {:ok, %{count: 42}} =
             Aikido.AgentServer.call(parent, signal("test.noop"), &{:ok, &1.agent.state.state})

    send(starter, :release_activation)
    assert {:ok, child} = Aikido.AgentServer.await_child(parent, :slow)
    assert {:ok, ^parent} = Aikido.AgentServer.state(child, &{:ok, &1.parent.pid})
  end

  for policy <- [:stop, :continue, :emit_orphan] do
    test "parent death during activation preserves #{policy} policy", context do
      parent = start_server(context, __MODULE__.Harness, restart?: false)
      assert {:ok, :accepted} = send_directive(parent, slow_directive(unquote(policy)))
      assert_receive {:activation_waiting, starter}
      parent_monitor = Process.monitor(parent)
      GenServer.stop(parent)
      assert_receive {:DOWN, ^parent_monitor, :process, ^parent, _}
      send(starter, :release_activation)
      assert_receive {:activation_initialized, child}

      if unquote(policy) == :stop do
        monitor = Process.monitor(child)
        assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
      else
        await_state_value(child, fn runtime ->
          if runtime.orphaned_from, do: runtime, else: nil
        end)

        assert {:ok, %{parent: nil, orphaned_from: former, count: count}} =
                 Aikido.AgentServer.state(child, fn runtime ->
                   {:ok,
                    %{
                      parent: runtime.parent,
                      orphaned_from: runtime.orphaned_from,
                      count: runtime.agent.state.state.orphan_count
                    }}
                 end)

        assert former.pid == parent
        expected = if unquote(policy) == :emit_orphan, do: 1, else: 0
        assert count == expected
        GenServer.cast(child, {:ensure_initial_parent, former})

        assert {:ok, ^expected} =
                 Aikido.AgentServer.state(child, &{:ok, &1.agent.state.state.orphan_count})

        assert Process.alive?(child)
      end
    end
  end

  test "spawn task saturation is visible and leaves the owning agent responsive" do
    instance = :"spawn_capacity_#{System.unique_integer([:positive])}"
    start_supervised!({Aikido, name: instance, max_tasks: 1, durable: durable_options()})
    parent = start_server(%{aikido: instance}, __MODULE__.Harness)
    observer = self()

    {:ok, holder} =
      Task.Supervisor.start_child(Aikido.task_supervisor_name(instance), fn ->
        send(observer, :spawn_capacity_full)

        receive do
          :release_capacity -> :ok
        end
      end)

    assert_receive :spawn_capacity_full

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        generic = %Aikido.Directives.Spawn{
          child_spec: %{id: :ignored, start: {__MODULE__.IgnoredChild, :start_link, [self()]}}
        }

        assert {:ok, :accepted} = send_directive(parent, generic)
        assert {:ok, :accepted} = send_directive(parent, slow_directive(:stop))
      end)

    assert log =~ "Failed to start spawn task: :max_children"
    assert log =~ "Failed to start agent spawn task: :max_children"
    refute_received :generic_ignored
    refute_received {:activation_waiting, _}

    assert {:ok, %{count: 42}} =
             Aikido.AgentServer.call(parent, signal("test.noop"), &{:ok, &1.agent.state.state})

    monitor = Process.monitor(holder)
    send(holder, :release_capacity)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
  end

  defp slow_directive(policy) do
    %Aikido.Directives.SpawnAgent{
      agent: __MODULE__.SlowAgent,
      tag: :slow,
      opts: %{initial_state: %{observer: self(), block?: true}, on_parent_death: policy},
      restart?: false
    }
  end

  defp send_directive(pid, directive) do
    Aikido.AgentServer.call(pid, signal("test.spawn", %{directive: directive}), fn _ ->
      {:ok, :accepted}
    end)
  end
end
