defmodule AikidoTest.FSMTest.DefaultFSMAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "fsm_default"
    slice :fsm, Aikido.FSM.Slice
  end
end

defmodule AikidoTest.FSMTest.ConfiguredFSMAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "fsm_configured"

    slice :fsm, Aikido.FSM.Slice,
      options: [
        initial_state: "ready",
        transitions: %{
          "ready" => ["working", "done"],
          "working" => ["ready", "done", "errored"],
          "done" => [],
          "errored" => []
        },
        terminal_states: ["done", "errored"]
      ]
  end
end

defmodule AikidoTest.FSMTest do
  use ExUnit.Case, async: true

  describe("Slice.Info surface") do
    test "FSM signal_routes routes aikido.fsm.transition" do
      assert {"aikido.fsm.transition", {Aikido.FSM.Slice, :transition}} in Aikido.Slice.Info.signal_routes(
               Aikido.FSM.Slice
             )
    end

    test "FSM owns the native transition action" do
      assert {Aikido.FSM.Slice, :transition} in Aikido.Slice.Info.actions(Aikido.FSM.Slice)
    end

    test "the slice action runs directly through Ash with its declared arguments" do
      assert Ash.Resource.Info.resource?(Aikido.FSM.Slice)
      assert Aikido.Slice.Extension in Spark.extensions(Aikido.FSM.Slice)
      state = AikidoTest.FSMTest.ConfiguredFSMAgent.initialize!().state.fsm

      input =
        Ash.ActionInput.for_action(Aikido.FSM.Slice, :transition, %{state: state, to: "working"})

      assert {:ok, %Aikido.Types.ActionResult{changes: next, directives: []}} =
               Ash.run_action(input)

      assert next.state == "working"
      assert next.history == [%{from: "ready", to: "working"}]
      assert state.state == "ready"
    end
  end

  describe("default FSM (no per-agent config)") do
    test "agent boots with the default initial_state" do
      agent = AikidoTest.FSMTest.DefaultFSMAgent.initialize!()
      assert agent.state.fsm.state == "idle"
      assert agent.state.fsm.initial_state == "idle"
      assert agent.state.fsm.history == []
      assert agent.state.fsm.terminal? == false
    end

    test "an allowed transition mutates state" do
      agent = AikidoTest.FSMTest.DefaultFSMAgent.initialize!()

      {:ok, %{agent: agent}, _} =
        apply_transition(agent, "processing")

      assert agent.state.fsm.state == "processing"
      assert [%{from: "idle", to: "processing"}] = agent.state.fsm.history
    end

    test "transitioning into a terminal state flips terminal?" do
      agent = AikidoTest.FSMTest.DefaultFSMAgent.initialize!()

      {:ok, %{agent: agent}, _} =
        apply_transition(agent, "processing")

      {:ok, %{agent: agent}, _} =
        apply_transition(agent, "completed")

      assert agent.state.fsm.state == "completed"
      assert agent.state.fsm.terminal? == true
    end
  end

  test "initialization derives terminal status only when no explicit boolean is supplied" do
    for {attributes, expected} <- [
          {%{state: "done", terminal_states: ["done"]}, true},
          {%{state: "done", terminal_states: ["done"], terminal?: false}, false},
          {%{state: "ready", terminal_states: ["done"], terminal?: true}, true}
        ] do
      assert {:ok, record} =
               Aikido.FSM.Slice
               |> Ash.Changeset.for_create(:create, attributes)
               |> Ash.create()

      assert record.terminal? == expected

      scenario = AikidoTest.SliceState.new(Aikido.FSM.Slice, attributes)
      assert scenario.terminal? == expected

      agent =
        AikidoTest.FSMTest.ConfiguredFSMAgent.initialize!(%{
          state: %{fsm: attributes}
        })

      assert agent.state.fsm.terminal? == expected
    end
  end

  test "history records successful native transitions in chronological order" do
    initial = AikidoTest.FSMTest.DefaultFSMAgent.initialize!().state.fsm

    final =
      Enum.reduce(["processing", "idle", "processing"], initial, fn to, state ->
        input =
          Ash.ActionInput.for_action(Aikido.FSM.Slice, :transition, %{state: state, to: to})

        assert {:ok, %Aikido.Types.ActionResult{changes: next, directives: []}} =
                 Ash.run_action(input)

        Ash.update!(state, next, action: :update)
      end)

    assert final.history == [
             %{from: "idle", to: "processing"},
             %{from: "processing", to: "idle"},
             %{from: "idle", to: "processing"}
           ]

    assert initial.history == []
  end

  describe("configured FSM") do
    test "mount options initialize the configured FSM state" do
      agent = AikidoTest.FSMTest.ConfiguredFSMAgent.initialize!()
      assert agent.state.fsm.state == "ready"
      assert agent.state.fsm.terminal_states == ["done", "errored"]
      assert agent.state.fsm.terminal? == false
    end

    test "respects the configured transitions map" do
      agent = AikidoTest.FSMTest.ConfiguredFSMAgent.initialize!()

      {:ok, %{agent: agent}, _} =
        apply_transition(agent, "working")

      assert agent.state.fsm.state == "working"

      {:ok, %{agent: agent}, _} =
        apply_transition(agent, "errored")

      assert agent.state.fsm.state == "errored"
      assert agent.state.fsm.terminal? == true
    end

    test "rejects a transition not in the allowed list" do
      agent = AikidoTest.FSMTest.ConfiguredFSMAgent.initialize!()

      assert {:error, _, _reason} =
               apply_transition(agent, "unknown")
    end
  end

  defp apply_transition(agent, destination) do
    signal = %Aikido.Signal{id: nil, type: "test.action", data: %{}, source: "/test"}
    context = %{agent_module: agent.agent_module, agent: agent, agent_id: agent.id}

    Aikido.AgentServer.apply_actions(signal, context, [
      {{Aikido.FSM.Slice, :transition}, %{to: destination}}
    ])
  end
end
