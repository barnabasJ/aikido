defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.SetMultipleKeysAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    slice = slice || %{}

    Aikido.Types.ActionResult.new(
      state: Map.merge(slice, %{action_ran: true, key_a: true, key_b: true, key_c: true}),
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.ObserveAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    slice = slice || %{}

    observation = %{
      saw_action: Map.get(slice, :action_ran, false),
      saw_a: Map.get(slice, :key_a, false),
      saw_b: Map.get(slice, :key_b, false),
      saw_c: Map.get(slice, :key_c, false)
    }

    Aikido.Types.ActionResult.new(state: Map.merge(slice, observation), directives: [])
  end
end

defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.AtomicityAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "atomicity_agent"
    path :domain

    schema do
      attribute :action_ran, :boolean do
        description "Whether the reducer completed before directive execution."
        default false
      end

      attribute :key_a, :boolean do
        description "Whether the first directive's state marker was recorded."
        default false
      end

      attribute :key_b, :boolean do
        description "Whether the second directive's state marker was recorded."
        default false
      end

      attribute :key_c, :boolean do
        description "Whether the third directive's state marker was recorded."
        default false
      end

      attribute :saw_action, :boolean do
        description "Whether observers saw the reducer's committed state."
        default false
      end

      attribute :saw_a, :boolean do
        description "Whether observers saw the first directive's state marker."
        default false
      end

      attribute :saw_b, :boolean do
        description "Whether observers saw the second directive's state marker."
        default false
      end

      attribute :saw_c, :boolean do
        description "Whether observers saw the third directive's state marker."
        default false
      end
    end

    route "set_multiple",
          {AikidoTest.AgentServer.MultiDirectiveAtomicityTest.AtomicityAgent, :set_multiple}

    route "observe", {AikidoTest.AgentServer.MultiDirectiveAtomicityTest.AtomicityAgent, :observe}
  end

  actions do
    action :set_multiple, Aikido.Types.ActionResult do
      argument :state, :term

      run AikidoTest.AgentServer.MultiDirectiveAtomicityTest.SetMultipleKeysAction.Implementation
    end

    action :observe, Aikido.Types.ActionResult do
      argument :state, :term

      run AikidoTest.AgentServer.MultiDirectiveAtomicityTest.ObserveAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest do
  @moduledoc """
  Directives mutate no state. Action results own domain state changes;
  cascade callbacks invoked from `process_signal/2` own runtime bookkeeping.
  An action returning a multi-key slice is committed atomically before the
  next signal is pulled from the mailbox.

  Signal A's action returns a slice with `{a: true, b: true, c: true}`.
  Signal B is cast right after. With inline signal processing, signal B's
  `action` must observe **all three keys** set —
  not a partial prefix.
  """
  use AikidoTest.Case, async: true

  describe("multi-key slice atomicity") do
    test("signal B observes every slice key set by signal A's action result", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.MultiDirectiveAtomicityTest.AtomicityAgent
        )

      Aikido.AgentServer.cast(pid, signal("set_multiple", %{}))
      Aikido.AgentServer.cast(pid, signal("observe", %{}))

      domain =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.saw_c do
            s.agent.state.domain
          end
        end)

      assert domain.action_ran
      assert domain.key_a
      assert domain.key_b
      assert domain.key_c
      assert domain.saw_action
      assert domain.saw_a
      assert domain.saw_b
      assert domain.saw_c
    end
  end
end
