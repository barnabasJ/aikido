defmodule AikidoTest.Slices.FSMTest.DefaultFSMAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "fsm_default"
    slice :fsm, Aikido.Slices.FSM
  end
end

defmodule AikidoTest.Slices.FSMTest.ConfiguredFSMAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "fsm_configured"

    slice :fsm, Aikido.Slices.FSM,
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

defmodule AikidoTest.Slices.FSMTest do
  use ExUnit.Case, async: true

  describe("Slice.Info surface") do
    test "FSM signal_routes routes aikido.fsm.transition" do
      assert {"aikido.fsm.transition", {Aikido.Slices.FSM, :transition}} in Aikido.Dsl.Slice.Info.signal_routes(
               Aikido.Slices.FSM
             )
    end

    test "FSM owns the native transition action" do
      assert {Aikido.Slices.FSM, :transition} in Aikido.Dsl.Slice.Info.actions(Aikido.Slices.FSM)
    end

    test "the slice action runs directly through Ash with its declared arguments" do
      assert Ash.Resource.Info.resource?(Aikido.Slices.FSM)
      assert Aikido.Ash.Slice in Spark.extensions(Aikido.Slices.FSM)
      state = AikidoTest.Slices.FSMTest.ConfiguredFSMAgent.initialize!().state.fsm

      input =
        Ash.ActionInput.for_action(Aikido.Slices.FSM, :transition, %{state: state, to: "working"})

      assert {:ok, %Aikido.ActionResult{state: next, directives: []}} = Ash.run_action(input)
      assert next.state == "working"
      assert next.history == [%{from: "ready", to: "working"}]
      assert state.state == "ready"
    end
  end

  describe("default FSM (no per-agent config)") do
    test "agent boots with the default initial_state" do
      agent = AikidoTest.Slices.FSMTest.DefaultFSMAgent.initialize!()
      assert agent.state.fsm.state == "idle"
      assert agent.state.fsm.initial_state == "idle"
      assert agent.state.fsm.history == []
      assert agent.state.fsm.terminal? == false
    end

    test "an allowed transition mutates state" do
      agent = AikidoTest.Slices.FSMTest.DefaultFSMAgent.initialize!()

      {:ok, %{agent: agent}, _} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Slices.FSMTest.DefaultFSMAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.FSM, :transition}, %{to: "processing"}}]
        )

      assert agent.state.fsm.state == "processing"
      assert [%{from: "idle", to: "processing"}] = agent.state.fsm.history
    end

    test "transitioning into a terminal state flips terminal?" do
      agent = AikidoTest.Slices.FSMTest.DefaultFSMAgent.initialize!()

      {:ok, %{agent: agent}, _} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Slices.FSMTest.DefaultFSMAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.FSM, :transition}, %{to: "processing"}}]
        )

      {:ok, %{agent: agent}, _} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Slices.FSMTest.DefaultFSMAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.FSM, :transition}, %{to: "completed"}}]
        )

      assert agent.state.fsm.state == "completed"
      assert agent.state.fsm.terminal? == true
    end
  end

  test "history records successful native transitions in chronological order" do
    initial = AikidoTest.Slices.FSMTest.DefaultFSMAgent.initialize!().state.fsm

    final =
      Enum.reduce(["processing", "idle", "processing"], initial, fn to, state ->
        input =
          Ash.ActionInput.for_action(Aikido.Slices.FSM, :transition, %{state: state, to: to})

        assert {:ok, %Aikido.ActionResult{state: next, directives: []}} = Ash.run_action(input)
        next
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
      agent = AikidoTest.Slices.FSMTest.ConfiguredFSMAgent.initialize!()
      assert agent.state.fsm.state == "ready"
      assert agent.state.fsm.terminal_states == ["done", "errored"]
      assert agent.state.fsm.terminal? == false
    end

    test "respects the configured transitions map" do
      agent = AikidoTest.Slices.FSMTest.ConfiguredFSMAgent.initialize!()

      {:ok, %{agent: agent}, _} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Slices.FSMTest.ConfiguredFSMAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.FSM, :transition}, %{to: "working"}}]
        )

      assert agent.state.fsm.state == "working"

      {:ok, %{agent: agent}, _} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Slices.FSMTest.ConfiguredFSMAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.FSM, :transition}, %{to: "errored"}}]
        )

      assert agent.state.fsm.state == "errored"
      assert agent.state.fsm.terminal? == true
    end

    test "rejects a transition not in the allowed list" do
      agent = AikidoTest.Slices.FSMTest.ConfiguredFSMAgent.initialize!()

      assert {:error, _, _reason} =
               Aikido.AgentServer.apply_actions(
                 struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
                 Map.merge(
                   Aikido.SignalCtx.ctx(
                     struct!(Jido.Signal,
                       id: nil,
                       type: "test.action",
                       data: %{},
                       source: "/test"
                     )
                   ),
                   Map.merge(%{}, %{
                     agent_module: AikidoTest.Slices.FSMTest.ConfiguredFSMAgent,
                     agent: agent,
                     agent_id: agent.id
                   })
                 ),
                 [{{Aikido.Slices.FSM, :transition}, %{to: "unknown"}}]
               )
    end
  end
end
