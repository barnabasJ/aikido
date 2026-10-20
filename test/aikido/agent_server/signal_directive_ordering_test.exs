defmodule AikidoTest.AgentServer.SignalDirectiveOrderingTest.Step1Action.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    slice = slice || %{}
    followup = struct!(Jido.Signal, id: nil, type: "step1.followup", source: "/test", data: %{})

    Aikido.ActionResult.new(
      state: Map.put(slice, :step1_action_ran, true),
      directives: [Aikido.Directives.emit(followup)]
    )
  end
end

defmodule AikidoTest.AgentServer.SignalDirectiveOrderingTest.SetFollowupKeyAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    slice = slice || %{}
    Aikido.ActionResult.new(state: Map.put(slice, :step1_followup_ran, true), directives: [])
  end
end

defmodule AikidoTest.AgentServer.SignalDirectiveOrderingTest.Step2Action.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    slice = slice || %{}
    saw_action = Map.get(slice, :step1_action_ran, false)

    Aikido.ActionResult.new(
      state: Map.put(slice, :step2_saw_action_ran, saw_action),
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServer.SignalDirectiveOrderingTest.OrderingAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "ordering_agent"
    path :domain

    schema do
      attribute :step1_action_ran, :boolean, default: false
      attribute :step1_followup_ran, :boolean, default: false
      attribute :step2_saw_action_ran, :boolean, default: false
    end

    route "step1", {AikidoTest.AgentServer.SignalDirectiveOrderingTest.OrderingAgent, :step1}

    route "step1.followup",
          {AikidoTest.AgentServer.SignalDirectiveOrderingTest.OrderingAgent, :set_followup_key}

    route "step2", {AikidoTest.AgentServer.SignalDirectiveOrderingTest.OrderingAgent, :step2}
  end

  actions do
    action :step1, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.SignalDirectiveOrderingTest.Step1Action.Implementation,
           action: :run}
    end

    action :set_followup_key, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.SignalDirectiveOrderingTest.SetFollowupKeyAction.Implementation,
           action: :run}
    end

    action :step2, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.SignalDirectiveOrderingTest.Step2Action.Implementation,
           action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.SignalDirectiveOrderingTest do
  @moduledoc """
  Tests the ordering guarantee between signal processing (native Ash actions)
  and directive execution under inline signal processing.

  Directives mutate no state; the cascade-driven
  state changes happen on whatever turn observes the resulting signal.
  Signal A emits an `Emit` directive whose dispatched signal routes via
  `signal_routes` to a state-mutating action; signal A also returns a
  action-returned slice change. Signal B is cast immediately after.

  When two async signals are cast, signal A runs fully — action *and*
  any inline directive I/O — before signal B is picked up from the
  mailbox. So signal B's action always sees signal A's slice
  return; the dispatched signal arrives later in the mailbox and is
  processed in its own turn.
  """
  use AikidoTest.Case, async: true

  describe("inline signal processing ordering") do
    test("signal B sees signal A's action-returned slice update", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.SignalDirectiveOrderingTest.OrderingAgent
        )

      Aikido.AgentServer.cast(pid, signal("step1", %{}))
      Aikido.AgentServer.cast(pid, signal("step2", %{}))

      agent_state =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.step2_saw_action_ran do
            s.agent.state.domain
          end
        end)

      assert agent_state.step1_action_ran == true
      assert agent_state.step2_saw_action_ran == true
    end

    test("the emitted follow-up signal eventually runs and updates state", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.SignalDirectiveOrderingTest.OrderingAgent
        )

      Aikido.AgentServer.cast(pid, signal("step1", %{}))

      assert true =
               AikidoTest.AgentWait.await_state_value(
                 pid,
                 fn s -> s.agent.state.domain.step1_followup_ran || nil end,
                 pattern: "step1.followup"
               )
    end
  end
end
