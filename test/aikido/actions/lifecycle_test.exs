defmodule AikidoTest.Actions.LifecycleTest do
  use ExUnit.Case, async: true
  alias Aikido.AgentServer.ParentRef
  alias Aikido.Directives
  alias Jido.Signal

  defp sig(type, data) do
    Signal.new!(%{type: type, source: "/test", data: data})
  end

  describe("NotifyParent") do
    test "creates emit directive to parent when ctx.parent has a pid" do
      parent_pid = self()
      parent = %ParentRef{pid: parent_pid, id: "parent-1", tag: :child, meta: %{}}
      data = %{signal_type: "child.done", payload: %{result: 42}, source: "/child"}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: directives}} =
        then(sig("notify_parent", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:notify_parent, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{parent: parent}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{notified: true}
      assert [%Directives.Emit{} = emit] = directives
      assert emit.signal.type == "child.done"
      assert emit.signal.data == %{result: 42}
      assert emit.dispatch == {:pid, target: parent_pid}
    end

    test "returns notified: false when ctx.parent is nil (orphaned)" do
      data = %{signal_type: "child.done", payload: %{}, source: "/child"}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: directives}} =
        then(sig("notify_parent", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:notify_parent, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{parent: nil}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{notified: false}
      assert directives == []
    end
  end

  describe("NotifyPid") do
    test "creates emit directive to specified pid" do
      target = self()

      data = %{
        target_pid: target,
        signal_type: "result.ready",
        payload: %{data: "test"},
        source: "/agent",
        delivery_mode: :async
      }

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("notify_pid", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:notify_pid, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{sent_to: target}
      assert %Directives.Emit{} = directive
      assert directive.signal.type == "result.ready"
      assert directive.signal.data == %{data: "test"}
      assert {:pid, opts} = directive.dispatch
      assert Keyword.get(opts, :target) == target
      assert Keyword.get(opts, :delivery_mode) == :async
    end

    test "supports sync delivery mode" do
      target = self()

      data = %{
        target_pid: target,
        signal_type: "sync.request",
        payload: %{},
        source: "/agent",
        delivery_mode: :sync
      }

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("notify_pid", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:notify_pid, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert {:pid, opts} = directive.dispatch
      assert Keyword.get(opts, :target) == target
      assert Keyword.get(opts, :delivery_mode) == :sync
    end
  end

  describe("SpawnChild") do
    test "creates spawn_agent directive" do
      data = %{
        agent_module: AikidoTest.TestAgents.Minimal,
        tag: :worker_1,
        initial_state: %{batch_size: 100},
        meta: %{assigned: true},
        restart?: true
      }

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("spawn_child", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:spawn_child, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{spawning: :worker_1}
      assert %Directives.SpawnAgent{} = directive
      assert directive.agent == AikidoTest.TestAgents.Minimal
      assert directive.tag == :worker_1
      assert directive.opts == %{initial_state: %{batch_size: 100}}
      assert directive.meta == %{assigned: true}
      assert directive.restart? == true
    end

    test "uses empty opts when no initial_state" do
      data = %{
        agent_module: AikidoTest.TestAgents.Minimal,
        tag: :worker_2,
        initial_state: %{},
        meta: %{},
        restart?: false
      }

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("spawn_child", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:spawn_child, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directive.opts == %{}
      assert directive.restart? == false
    end
  end

  describe("StopSelf") do
    test "creates stop directive with normal reason" do
      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("stop_self", %{reason: :normal}), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:stop_self, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{stopping: true, reason: :normal}
      assert %Directives.Stop{} = directive
      assert directive.reason == :normal
    end

    test "supports custom stop reasons" do
      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("stop_self", %{reason: :work_complete}), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:stop_self, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{stopping: true, reason: :work_complete}
      assert directive.reason == :work_complete
    end
  end

  describe("StopChild") do
    test "creates stop_child directive" do
      data = %{tag: :worker_1, reason: :normal}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("stop_child", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:stop_child, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{stopping_child: :worker_1, reason: :normal}
      assert %Directives.StopChild{} = directive
      assert directive.tag == :worker_1
      assert directive.reason == :normal
    end

    test "supports custom stop reasons" do
      data = %{tag: :processor, reason: :shutdown}

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("stop_child", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:stop_child, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directive.reason == :shutdown
    end
  end
end
