defmodule Aikido.Slices.FSMSmokeTest.DefaultFSMAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "default_fsm_agent"
  end

  slices do
    slice :fsm, Aikido.Slices.FSM
  end
end

defmodule Aikido.Slices.FSMSmokeTest.ConfiguredFSMAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "configured_fsm_agent"
  end

  slices do
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

defmodule Aikido.Slices.FSMSmokeTest do
  @moduledoc """
  Smoke coverage for the pure FSM slice.
  """
  use ExUnit.Case, async: true

  describe("agent boot") do
    test "an agent with `plugins: [Aikido.Slices.FSM]` starts with default slice state" do
      agent = Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.new()
      assert agent.state.fsm.state == "idle"
      assert agent.state.fsm.history == []
      assert agent.state.fsm.terminal? == false
      assert agent.state.fsm.initial_state == "idle"
      assert is_map(agent.state.fsm.transitions)
      assert "completed" in agent.state.fsm.terminal_states
    end

    test "per-agent config seeds the slice via mount/2" do
      agent = Aikido.Slices.FSMSmokeTest.ConfiguredFSMAgent.new()
      assert agent.state.fsm.state == "ready"
      assert agent.state.fsm.initial_state == "ready"
      assert agent.state.fsm.terminal_states == ["done", "errored"]
    end
  end

  describe("transition action") do
    test "a routed transition signal mutates `agent.state.fsm.state`" do
      agent = Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.new()

      {:ok, agent, _directives} =
        Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.cmd(
          agent,
          {{Aikido.Slices.FSM, :transition}, %{to: "processing"}}
        )

      assert agent.state.fsm.state == "processing"
      assert length(agent.state.fsm.history) == 1
    end

    test "transitioning into a terminal state flips `terminal?`" do
      agent = Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.new()

      {:ok, agent, _} =
        Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.cmd(
          agent,
          {{Aikido.Slices.FSM, :transition}, %{to: "processing"}}
        )

      {:ok, agent, _} =
        Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.cmd(
          agent,
          {{Aikido.Slices.FSM, :transition}, %{to: "completed"}}
        )

      assert agent.state.fsm.state == "completed"
      assert agent.state.fsm.terminal? == true
    end

    test "history records one entry per successful transition, oldest first" do
      agent = Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.new()

      {:ok, agent, _} =
        Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.cmd(
          agent,
          {{Aikido.Slices.FSM, :transition}, %{to: "processing"}}
        )

      {:ok, agent, _} =
        Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.cmd(
          agent,
          {{Aikido.Slices.FSM, :transition}, %{to: "idle"}}
        )

      {:ok, agent, _} =
        Aikido.Slices.FSMSmokeTest.DefaultFSMAgent.cmd(
          agent,
          {{Aikido.Slices.FSM, :transition}, %{to: "processing"}}
        )

      assert [
               %{from: "idle", to: "processing"},
               %{from: "processing", to: "idle"},
               %{from: "idle", to: "processing"}
             ] = agent.state.fsm.history
    end
  end
end
