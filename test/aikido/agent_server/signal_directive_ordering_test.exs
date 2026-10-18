defmodule AikidoTest.AgentServer.SignalDirectiveOrderingTest do
  @moduledoc "Tests the ordering guarantee between signal processing (Agent.cmd/2)\nand directive execution under inline signal processing (ADR 0009).\n\nPer ADR 0019 / task 0015, directives mutate no state; the cascade-driven\nstate changes happen on whatever turn observes the resulting signal.\nSignal A emits an `Emit` directive whose dispatched signal routes via\n`signal_routes` to a state-mutating action; signal A also returns a\ncmd-level slice change. Signal B is cast immediately after.\n\nWhen two async signals are cast, signal A runs fully — cmd/2 *and*\nany inline directive I/O — before signal B is picked up from the\nmailbox. So signal B's cmd/2 always sees signal A's slice\nreturn; the dispatched signal arrives later in the mailbox and is\nprocessed in its own turn.\n"
  use AikidoTest.Case, async: true

  defmodule Step1Action do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "step1"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    alias Aikido.Directives
    alias Jido.Signal

    defp reduce(_signal, slice, _opts, _ctx) do
      slice = slice || %{}

      # Signal A's slice update is committed atomically before signal B
      # runs. The Emit directive then casts a `step1.followup` signal —
      # processed in a later mailbox turn by SetFollowupKeyAction.
      followup = Signal.new!(%{type: "step1.followup", source: "/test", data: %{}})
      {:ok, Map.put(slice, :step1_cmd_ran, true), [Directives.emit(followup)]}
    end
  end

  defmodule SetFollowupKeyAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "set_followup_key"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      {:ok, Map.put(slice, :step1_followup_ran, true), []}
    end
  end

  defmodule Step2Action do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "step2"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(_signal, slice, _opts, _ctx) do
      slice = slice || %{}
      saw_cmd = Map.get(slice, :step1_cmd_ran, false)
      {:ok, Map.put(slice, :step2_saw_cmd_ran, saw_cmd), []}
    end
  end

  defmodule OrderingAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("ordering_agent")
      path(:domain)

      schema do
        attribute(:step1_cmd_ran, :boolean, default: false)
        attribute(:step1_followup_ran, :boolean, default: false)
        attribute(:step2_saw_cmd_ran, :boolean, default: false)
      end
    end

    signal_routes do
      route("step1", Step1Action)
      route("step1.followup", SetFollowupKeyAction)
      route("step2", Step2Action)
    end
  end

  describe("inline signal processing ordering") do
    test("signal B sees signal A's cmd-level slice update", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, OrderingAgent)
      Aikido.AgentServer.cast(pid, signal("step1", %{}))
      Aikido.AgentServer.cast(pid, signal("step2", %{}))

      agent_state =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.step2_saw_cmd_ran do
            s.agent.state.domain
          end
        end)

      assert agent_state.step1_cmd_ran == true
      assert agent_state.step2_saw_cmd_ran == true
    end

    test("the emitted follow-up signal eventually runs and updates state", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, OrderingAgent)
      Aikido.AgentServer.cast(pid, signal("step1", %{}))

      # The Emit directive on step1 dispatched a `step1.followup` signal
      # back through the same agent; SetFollowupKeyAction sets the key.
      assert true =
               AikidoTest.AgentWait.await_state_value(
                 pid,
                 fn s -> s.agent.state.domain.step1_followup_ran || nil end,
                 pattern: "step1.followup"
               )
    end
  end
end
