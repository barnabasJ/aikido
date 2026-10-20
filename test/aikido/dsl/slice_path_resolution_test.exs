defmodule Aikido.Dsl.SlicePathResolutionTest.CounterSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "resolution_counter_slice"

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0
    end

    route "counter.bump", {Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :bump}
    route "counter.escape", {Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :escape}
  end

  actions do
    action :bump, Aikido.ActionResult do
      argument :state, :term
      run {Aikido.Dsl.SlicePathResolutionTest.BumpAction.Implementation, action: :run}
    end

    action :escape, Aikido.ActionResult do
      argument :state, :term
      run {Aikido.Dsl.SlicePathResolutionTest.EscapeAction.Implementation, action: :run}
    end

    action :unbound, Aikido.ActionResult do
      argument :state, :term
      run {Aikido.Dsl.SlicePathResolutionTest.UnboundAction.Implementation, action: :run}
    end
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.BumpAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state

    Aikido.ActionResult.new(
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
    Aikido.ActionResult.new(state: Map.put(slice || %{count: 0}, :tagged, true), directives: [])
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.UnboundAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    Aikido.ActionResult.new(state: Map.put(slice || %{}, :stamped, true), directives: [])
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "resolution_agent"
    path :domain

    schema do
      attribute :last_action, :atom, default: nil
    end

    slice :counter, Aikido.Dsl.SlicePathResolutionTest.CounterSlice
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest do
  @moduledoc """
  Targeted coverage for the `__resolve_slice_paths__/1` resolution
  order:

    1. Every mount that routes to the action via its `signal_routes`
       (the compile-time `:slice_paths_for_action` lookup table). Returns
       a list — multi-instance mounts contribute multiple entries; the
       agent's own path is appended when the agent's own `signal_routes`
       also declares the action.
    2. Fallback (when the table has no entry for the action): the
       action's own `path :foo` escape valve (for ad-hoc actions on the
       agent's own `signal_routes` that aren't owned by any slice).
    3. Final fallback: the agent's own `path :foo` (its `agent do … end`
       slice).

  Steps 2 and 3 yield a single-element list so the runtime fan-out fold
  in the native action pipeline is uniform across single-mount and
  multi-mount cases.
  """
  use ExUnit.Case, async: true

  describe("slice that routes to the action wins") do
    test "BumpAction (in CounterSlice's signal_routes) writes to :counter, not :domain" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.initialize!()
      assert %{count: 0} = agent.state.counter

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
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

    test "BumpAction has no `path :foo` of its own — resolution comes from the slice mount" do
      assert Map.get(
               Ash.Resource.Info.action(Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :bump),
               :path
             ) == nil
    end
  end

  describe("explicit slice ownership") do
    test "EscapeAction writes to the counter slice that declares its route" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.initialize!()

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
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
        Aikido.Dsl.Agent.Info.slice_paths_for_action(
          Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent
        )

      assert paths[{Aikido.Dsl.SlicePathResolutionTest.CounterSlice, :escape}] == [:counter]
    end
  end

  describe("fall back to agent's own path") do
    test "UnboundAction (no slice routes, no own path) writes to the agent's :domain slice" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.initialize!()

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
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
    test "slice_paths_for_action maps each slice action module to a list of mount paths" do
      table =
        Aikido.Dsl.Agent.Info.slice_paths_for_action(
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
