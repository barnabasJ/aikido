defmodule Aikido.Dsl.SlicePathResolutionTest.CounterSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "resolution_counter_slice"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        allow_nil? false
        default 0
      end
    end

    route "counter.bump", {Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :bump}
    route "counter.escape", {Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :escape}
  end

  actions do
    action :bump, Aikido.Types.ActionResult do
      argument :state, :term
      run Aikido.Dsl.SlicePathResolutionTest.BumpAction.Implementation
    end

    action :escape, Aikido.Types.ActionResult do
      argument :state, :term
      run Aikido.Dsl.SlicePathResolutionTest.EscapeAction.Implementation
    end

    action :unbound, Aikido.Types.ActionResult do
      argument :state, :term
      run Aikido.Dsl.SlicePathResolutionTest.UnboundAction.Implementation
    end
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.BumpAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: %{slice | count: (Map.get(slice, :count) || 0) + 1},
      directives: []
    )
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.EscapeAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Map.put(slice || %{count: 0}, :tagged, true),
      directives: []
    )
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.UnboundAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    Aikido.Types.ActionResult.new(state: Map.put(slice || %{}, :stamped, true), directives: [])
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "resolution_agent"
    path :domain

    schema do
      attribute :last_action, :atom do
        description "Most recent reducer action selected by routing."
        default nil
      end
    end

    slice :counter, Aikido.Dsl.SlicePathResolutionTest.CounterSlice
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest do
  @moduledoc """
  Actions routed by mounted slices write to every matching mount path. Actions
  also routed by the agent include its own state path. An action absent from
  the mount table writes to the agent's own state path.
  """
  use ExUnit.Case, async: true

  describe("slice that routes to the action wins") do
    test "a mounted slice action updates its own state path" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.initialize!()
      assert %{count: 0} = agent.state.counter

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          %Aikido.Signal{id: nil, type: "test.action", data: %{}, source: "/test"},
          Map.merge(
            Aikido.Signal.ctx(%Aikido.Signal{
              id: nil,
              type: "test.action",
              data: %{},
              source: "/test"
            }),
            Map.merge(%{}, %{
              agent_module: Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :bump}, %{}}]
        )

      assert %{count: 1} = agent.state.counter
      assert agent.state.domain == %{last_action: nil}
    end
  end

  describe("explicit slice ownership") do
    test "EscapeAction writes to the counter slice that declares its route" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.initialize!()

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          %Aikido.Signal{id: nil, type: "test.action", data: %{}, source: "/test"},
          Map.merge(
            Aikido.Signal.ctx(%Aikido.Signal{
              id: nil,
              type: "test.action",
              data: %{},
              source: "/test"
            }),
            Map.merge(%{}, %{
              agent_module: Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :escape}, %{}}]
        )

      assert Map.get(agent.state.counter, :tagged) == true
      assert agent.state.domain == %{last_action: nil}
    end

    test "the compiled mount table records explicit ownership" do
      paths =
        Aikido.Ash.Agent.Info.slice_paths_for_action(
          Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent
        )

      assert paths[{Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :escape}] == [:counter]
    end
  end

  describe("fall back to agent's own path") do
    test "an action absent from the mount table writes to the agent state path" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.initialize!()

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          %Aikido.Signal{id: nil, type: "test.action", data: %{}, source: "/test"},
          Map.merge(
            Aikido.Signal.ctx(%Aikido.Signal{
              id: nil,
              type: "test.action",
              data: %{},
              source: "/test"
            }),
            Map.merge(%{}, %{
              agent_module: Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :unbound}, %{}}]
        )

      assert agent.state.domain[:stamped] == true
      assert %{count: 0} = agent.state.counter
    end
  end

  describe("compile-time lookup table shape") do
    test "slice_paths_for_action maps resource/action pairs to mount paths" do
      table =
        Aikido.Ash.Agent.Info.slice_paths_for_action(
          Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent
        )

      assert is_map(table)

      assert Map.get(table, {Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :bump}) == [
               :counter
             ]

      assert table[{Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :escape}] == [:counter]
      refute Map.has_key?(table, {Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :unbound})
    end
  end
end
