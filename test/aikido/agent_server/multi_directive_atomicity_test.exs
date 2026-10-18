defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest do
  @moduledoc "Per ADR 0019 / task 0015 (terminal cleanup), directives mutate no\nstate — only `cmd/2`'s return slice and the cascade callbacks\ninvoked from `process_signal/2` write to `agent.state` /\n`%AgentServer.State{}`. The \"multi-directive atomicity\" question\nshifts: what's interesting now is that an action returning a\nmulti-key slice is committed atomically before the next signal is\npulled from the mailbox.\n\nSignal A's action returns a slice with `{a: true, b: true, c: true}`.\nSignal B is cast right after. Under inline signal processing\n(ADR 0009), signal B's `cmd/2` must observe **all three keys** set —\nnot a partial prefix.\n"
  use AikidoTest.Case, async: true

  defmodule SetMultipleKeysAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "set_multiple"}}
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
      {:ok, Map.merge(slice, %{cmd_ran: true, key_a: true, key_b: true, key_c: true}), []}
    end
  end

  defmodule ObserveAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "observe"}}
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

      observation = %{
        saw_cmd: Map.get(slice, :cmd_ran, false),
        saw_a: Map.get(slice, :key_a, false),
        saw_b: Map.get(slice, :key_b, false),
        saw_c: Map.get(slice, :key_c, false)
      }

      {:ok, Map.merge(slice, observation), []}
    end
  end

  defmodule AtomicityAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("atomicity_agent")
      path(:domain)

      schema do
        attribute(:cmd_ran, :boolean, default: false)
        attribute(:key_a, :boolean, default: false)
        attribute(:key_b, :boolean, default: false)
        attribute(:key_c, :boolean, default: false)
        attribute(:saw_cmd, :boolean, default: false)
        attribute(:saw_a, :boolean, default: false)
        attribute(:saw_b, :boolean, default: false)
        attribute(:saw_c, :boolean, default: false)
      end
    end

    signal_routes do
      route("set_multiple", SetMultipleKeysAction)
      route("observe", ObserveAction)
    end
  end

  describe("multi-key slice atomicity") do
    test("signal B observes every slice key set by signal A's cmd return", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AtomicityAgent)
      Aikido.AgentServer.cast(pid, signal("set_multiple", %{}))
      Aikido.AgentServer.cast(pid, signal("observe", %{}))

      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.saw_c do
            s.agent.state.domain
          end
        end)

      assert domain.cmd_ran
      assert domain.key_a
      assert domain.key_b
      assert domain.key_c

      # The guarantee: signal B sees the full slice signal A's cmd returned.
      assert domain.saw_cmd
      assert domain.saw_a
      assert domain.saw_b
      assert domain.saw_c
    end
  end
end
