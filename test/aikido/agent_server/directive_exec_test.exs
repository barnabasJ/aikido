defmodule AikidoTest.AgentServer.DirectiveExecTest.EmitDirectiveAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    directive =
      input.arguments.directive

    slice = input.arguments.state
    Aikido.Types.ActionResult.new(state: slice || %{}, directives: [directive])
  end
end

defmodule AikidoTest.AgentServer.DirectiveExecTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "directive_exec_test_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end

    route "test.directive", {AikidoTest.AgentServer.DirectiveExecTest.TestAgent, :emit_directive}
  end

  actions do
    action :emit_directive, Aikido.Types.ActionResult do
      argument :state, :term
      argument :directive, :term, allow_nil?: false

      run AikidoTest.AgentServer.DirectiveExecTest.EmitDirectiveAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.DirectiveExecTest.StopOnSignalAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments.reason
    directives = [%Aikido.Directives.Stop{reason: reason}]

    directives =
      if observer = Map.get(input.arguments.state, :observer_pid) do
        observation = %{
          input.context.aikido.signal
          | type: "test.child.stopping",
            data: %{reason: reason}
        }

        [Aikido.Directives.emit_to_pid(observation, observer) | directives]
      else
        directives
      end

    Aikido.Types.ActionResult.new(state: %{stop_reason: reason}, directives: directives)
  end
end

defmodule AikidoTest.AgentServer.DirectiveExecTest.StopAwareAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "directive_exec_stop_aware_agent"
    path :domain

    schema do
      attribute :observer_pid, :term, default: nil
      attribute :stop_reason, :term, default: nil
    end

    route "aikido.agent.stop",
          {AikidoTest.AgentServer.DirectiveExecTest.StopAwareAgent, :stop_on_signal}

    route "test.directive", {AikidoTest.AgentServer.DirectiveExecTest.TestAgent, :emit_directive}
  end

  actions do
    action :stop_on_signal, Aikido.Types.ActionResult do
      argument :state, :term
      argument :reason, :term, default: :normal

      run AikidoTest.AgentServer.DirectiveExecTest.StopOnSignalAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.DirectiveExecTest.CustomDirective do
  @moduledoc false
  defstruct [:value]
end

defmodule AikidoTest.AgentServer.DirectiveExecTest do
  use AikidoTest.Case, async: true

  setup %{aikido: aikido} do
    agent = AikidoTest.AgentServer.DirectiveExecTest.TestAgent.initialize!()

    {:ok, opts} =
      Aikido.AgentServer.Options.new(%{
        agent_module: AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
        id: "test-agent-123",
        aikido: aikido
      })

    {:ok, state} =
      Aikido.AgentServer.State.from_options(
        opts,
        AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
        agent
      )

    input_signal = Jido.Signal.new!(%{type: "test.signal", source: "/test", data: %{}})
    %{state: state, input_signal: input_signal, agent: agent}
  end

  describe("Emit directive") do
    test("falls back to dispatching to current process when no dispatch config", %{
      state: state,
      input_signal: input_signal
    }) do
      signal = Jido.Signal.new!(%{type: "test.emitted", source: "/test", data: %{}})
      directive = %Aikido.Directives.Emit{signal: signal, dispatch: nil}
      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
      assert_receive {:signal, %Jido.Signal{type: "test.emitted"}}
    end

    test("returns ok when dispatch config provided", %{state: state, input_signal: input_signal}) do
      signal = Jido.Signal.new!(%{type: "test.emitted", source: "/test", data: %{}})
      directive = %Aikido.Directives.Emit{signal: signal, dispatch: {:logger, level: :info}}
      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
    end

    test("uses default_dispatch from state when directive dispatch is nil", %{
      input_signal: input_signal,
      agent: agent,
      aikido: aikido
    }) do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(%{
          agent_module: AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
          id: "test-agent-dispatch",
          default_dispatch: {:logger, level: :debug},
          aikido: aikido
        })

      {:ok, state} = Aikido.AgentServer.State.from_options(opts, agent.__struct__, agent)
      signal = Jido.Signal.new!(%{type: "test.emitted", source: "/test", data: %{}})
      directive = %Aikido.Directives.Emit{signal: signal, dispatch: nil}
      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
    end
  end

  describe("Error directive") do
    test("logs the error and returns ok", %{
      state: state,
      input_signal: input_signal
    }) do
      error = Aikido.Error.validation_error("Test error")
      directive = %Aikido.Directives.Error{error: error, context: :test}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Aikido.Directive.exec(directive, input_signal, state)
        end)

      assert log =~ "Agent #{state.id} [test]"
      assert log =~ "Test error"
    end
  end

  describe "Spawn directive" do
    test "starts a supervised process", %{input_signal: signal, state: state} do
      caller = self()

      directive = %Aikido.Directives.Spawn{
        child_spec: {Task, fn -> send(caller, :spawned) end},
        tag: :worker
      }

      assert :ok = Aikido.Directive.exec(directive, signal, state)
      assert_receive :spawned
    end
  end

  describe("Schedule directive") do
    test("sends scheduled signal after delay", %{state: state, input_signal: input_signal}) do
      signal = Jido.Signal.new!(%{type: "scheduled.ping", source: "/test", data: %{}})
      directive = %Aikido.Directives.Schedule{delay_ms: 10, message: signal}
      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
      assert_receive {:scheduled_signal, received_signal}, 100
      assert received_signal.type == "scheduled.ping"
    end

    test("wraps non-signal message in signal", %{state: state, input_signal: input_signal}) do
      directive = %Aikido.Directives.Schedule{delay_ms: 10, message: :timeout}
      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
      assert_receive {:scheduled_signal, received_signal}, 100
      assert received_signal.type == "aikido.scheduled"
      assert received_signal.data.message == :timeout
    end
  end

  describe("Stop directive") do
    test("returns stop tuple with reason", %{state: state, input_signal: input_signal}) do
      directive = %Aikido.Directives.Stop{reason: :normal}

      assert {:stop, :normal} =
               Aikido.Directive.exec(directive, input_signal, state)
    end

    test("returns stop tuple with custom reason", %{state: state, input_signal: input_signal}) do
      directive = %Aikido.Directives.Stop{reason: {:shutdown, :user_requested}}

      assert {:stop, {:shutdown, :user_requested}} =
               Aikido.Directive.exec(directive, input_signal, state)
    end
  end

  describe("SpawnAgent directive") do
    test("natural child.started cascade adds the child after the directive returns", %{
      aikido: aikido
    }) do
      parent_pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
          id: "spawn-cascade-parent"
        )

      directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
        tag: :child_worker,
        opts: %{},
        meta: %{role: :worker}
      }

      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(directive))

      child_info =
        await_state_value(
          parent_pid,
          fn s -> Map.get(s.children, :child_worker) end,
          pattern: "aikido.agent.child.started"
        )

      assert is_pid(child_info.pid)
      assert child_info.module == AikidoTest.AgentServer.DirectiveExecTest.TestAgent
      assert child_info.tag == :child_worker
      assert child_info.meta == %{role: :worker}
      GenServer.stop(child_info.pid)
    end

    test("directive itself does not write state.children", %{
      aikido: aikido
    }) do
      parent_pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
          id: "spawn-strict-parent"
        )

      directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
        tag: :strict_child,
        opts: %{},
        meta: %{}
      }

      input_signal = Jido.Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

      {:ok, before_children} =
        Aikido.AgentServer.state(parent_pid, fn s ->
          children_before = s.children
          :ok = Aikido.Directive.exec(directive, input_signal, s)
          {:ok, %{before: children_before, after: s.children}}
        end)

      assert before_children.before == before_children.after
      child_pid = await_child_pid(parent_pid, :strict_child)
      GenServer.stop(child_pid)
    end

    test("handles spawn failure gracefully", %{state: state, input_signal: input_signal}) do
      directive = %Aikido.Directives.SpawnAgent{
        agent: NonExistentAgentModule,
        tag: :failing_child,
        opts: %{},
        meta: %{}
      }

      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
      refute Map.has_key?(state.children, :failing_child)
    end

    test("native types reject a missing agent module") do
      directive = %Aikido.Directives.SpawnAgent{
        agent: "not_a_module_or_struct",
        tag: :unknown_agent,
        opts: %{},
        meta: %{}
      }

      assert {:error, _} = Aikido.Types.Directive.cast_input(directive, [])
    end

    test("native types reject malformed options on raw directives") do
      directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
        tag: :bad_opts_child,
        opts: [:not_a_map],
        meta: %{}
      }

      assert {:error, _} = Aikido.Types.Directive.cast_input(directive, [])
    end
  end

  describe("StopChild directive") do
    test("sends aikido.agent.stop to child", %{aikido: aikido}) do
      parent_pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.DirectiveExecTest.StopAwareAgent,
          id: "stop-aware-parent-1"
        )

      spawn_directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveExecTest.StopAwareAgent,
        tag: :stop_signal_child,
        opts: %{initial_state: %{observer_pid: self()}},
        meta: %{}
      }

      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(spawn_directive))
      child_pid = await_child_pid(parent_pid, :stop_signal_child)
      child_ref = Process.monitor(child_pid)
      stop_directive = %Aikido.Directives.StopChild{tag: :stop_signal_child, reason: :shutdown}
      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(stop_directive))
      assert_receive {:signal, %{type: "test.child.stopping", data: %{reason: :shutdown}}}, 1000
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, {:shutdown, :permanent}}, 1000
    end

    test("wraps custom stop reasons as clean shutdowns", %{aikido: aikido}) do
      parent_pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.DirectiveExecTest.StopAwareAgent,
          id: "stop-aware-parent-2"
        )

      spawn_directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveExecTest.StopAwareAgent,
        tag: :custom_reason_child,
        opts: %{initial_state: %{observer_pid: self()}},
        meta: %{}
      }

      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(spawn_directive))
      child_pid = await_child_pid(parent_pid, :custom_reason_child)
      child_ref = Process.monitor(child_pid)
      stop_directive = %Aikido.Directives.StopChild{tag: :custom_reason_child, reason: :cleanup}
      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(stop_directive))

      assert_receive {:signal,
                      %{type: "test.child.stopping", data: %{reason: {:shutdown, :cleanup}}}},
                     1000

      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, {:shutdown, :permanent}}, 1000
    end

    test("stops existing child", %{aikido: aikido}) do
      parent_pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
          id: "stop-child-parent"
        )

      spawn_directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveExecTest.TestAgent,
        tag: :child_to_stop,
        opts: %{},
        meta: %{}
      }

      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(spawn_directive))
      child_pid = await_child_pid(parent_pid, :child_to_stop)
      stop_directive = %Aikido.Directives.StopChild{tag: :child_to_stop, reason: :normal}
      Aikido.AgentServer.cast(parent_pid, signal_carrying_directive(stop_directive))
      AikidoTest.LifecycleWait.await_down(child_pid)
    end

    test("returns ok when child tag not found", %{state: state, input_signal: input_signal}) do
      directive = %Aikido.Directives.StopChild{tag: :nonexistent_child, reason: :normal}
      assert :ok = Aikido.Directive.exec(directive, input_signal, state)
    end
  end

  describe("unknown directives") do
    test("rejects types without an execution implementation", %{
      state: state,
      input_signal: input_signal
    }) do
      directive = %AikidoTest.AgentServer.DirectiveExecTest.CustomDirective{value: 42}
      assert {:error, errors} = Aikido.Types.Directive.cast_input(directive, [])
      assert inspect(errors) =~ "does not implement"
      assert {:error, _} = Aikido.Types.ActionResult.new(state: %{}, directives: [directive])

      assert_raise UndefinedFunctionError, fn ->
        Aikido.Directive.exec(directive, input_signal, state)
      end
    end

    test "accepts implemented directives and rejects arbitrary terms" do
      directive = %Aikido.Directives.Stop{reason: :shutdown}
      assert {:ok, ^directive} = Aikido.Types.Directive.cast_input(directive, [])

      for value <- [nil, :unknown, %{}, "unknown"] do
        assert {:error, _} = Aikido.Types.Directive.cast_input(value, [])
      end
    end
  end

  defp signal_carrying_directive(directive) do
    Jido.Signal.new!(%{type: "test.directive", source: "/test", data: %{directive: directive}})
  end

  defp await_child_pid(parent_pid, tag) do
    info =
      await_state_value(
        parent_pid,
        fn s -> Map.get(s.children, tag) end,
        pattern: "aikido.agent.child.started"
      )

    info.pid
  end
end
