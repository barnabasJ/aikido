defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.SetMultipleKeysAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    slice = slice || %{}

    Aikido.ActionResult.new(
      state: Map.merge(slice, %{cmd_ran: true, key_a: true, key_b: true, key_c: true}),
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.SetMultipleKeysAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :set_multiple, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.MultiDirectiveAtomicityTest.SetMultipleKeysAction.Implementation,
           action: :run}
    end
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
      saw_cmd: Map.get(slice, :cmd_ran, false),
      saw_a: Map.get(slice, :key_a, false),
      saw_b: Map.get(slice, :key_b, false),
      saw_c: Map.get(slice, :key_c, false)
    }

    Aikido.ActionResult.new(state: Map.merge(slice, observation), directives: [])
  end
end

defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.ObserveAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :observe, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.MultiDirectiveAtomicityTest.ObserveAction.Implementation,
           action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.MultiDirectiveAtomicityTest.AtomicityAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "atomicity_agent"
    path :domain

    schema do
      attribute :cmd_ran, :boolean, default: false
      attribute :key_a, :boolean, default: false
      attribute :key_b, :boolean, default: false
      attribute :key_c, :boolean, default: false
      attribute :saw_cmd, :boolean, default: false
      attribute :saw_a, :boolean, default: false
      attribute :saw_b, :boolean, default: false
      attribute :saw_c, :boolean, default: false
    end
  end

  signal_routes do
    route "set_multiple",
          AikidoTest.AgentServer.MultiDirectiveAtomicityTest.SetMultipleKeysAction

    route "observe", AikidoTest.AgentServer.MultiDirectiveAtomicityTest.ObserveAction
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
  `cmd/2` must observe **all three keys** set —
  not a partial prefix.
  """
  use AikidoTest.Case, async: true

  describe("multi-key slice atomicity") do
    test("signal B observes every slice key set by signal A's cmd return", %{aikido: aikido}) do
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

      assert domain.cmd_ran
      assert domain.key_a
      assert domain.key_b
      assert domain.key_c
      assert domain.saw_cmd
      assert domain.saw_a
      assert domain.saw_b
      assert domain.saw_c
    end
  end
end
