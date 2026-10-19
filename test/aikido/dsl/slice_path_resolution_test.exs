defmodule Aikido.Dsl.SlicePathResolutionTest.CounterSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "resolution_counter_slice"

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0
    end
  end

  signal_routes do
    route "counter.bump", Aikido.Dsl.SlicePathResolutionTest.BumpAction
    route "counter.escape", Aikido.Dsl.SlicePathResolutionTest.EscapeAction
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.BumpAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    Aikido.ActionResult.new(state: %{slice | count: (slice[:count] || 0) + 1}, directives: [])
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.BumpAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :bump, Aikido.ActionResult do
      argument :state, :term
      run {Aikido.Dsl.SlicePathResolutionTest.BumpAction.Implementation, action: :run}
    end
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

defmodule Aikido.Dsl.SlicePathResolutionTest.EscapeAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :escape, Aikido.ActionResult do
      argument :state, :term
      run {Aikido.Dsl.SlicePathResolutionTest.EscapeAction.Implementation, action: :run}
    end
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

defmodule Aikido.Dsl.SlicePathResolutionTest.UnboundAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :unbound, Aikido.ActionResult do
      argument :state, :term
      run {Aikido.Dsl.SlicePathResolutionTest.UnboundAction.Implementation, action: :run}
    end
  end
end

defmodule Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "resolution_agent"
    path :domain

    schema do
      attribute :last_action, :atom, default: nil
    end
  end

  slices do
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
  in `__run_instruction__` is uniform across single-mount and
  multi-mount cases.
  """
  use ExUnit.Case, async: true

  describe("slice that routes to the action wins") do
    test "BumpAction (in CounterSlice's signal_routes) writes to :counter, not :domain" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.new()
      assert agent.state.counter == %{count: 0}

      {:ok, agent, _dirs} =
        Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.cmd(
          agent,
          Aikido.Dsl.SlicePathResolutionTest.BumpAction
        )

      assert agent.state.counter == %{count: 1}
      assert agent.state.domain == %{last_action: nil}
    end

    test "BumpAction has no `path :foo` of its own — resolution comes from the slice mount" do
      assert Map.get(
               Aikido.ActionRef.definition(Aikido.Dsl.SlicePathResolutionTest.BumpAction),
               :path
             ) == nil
    end
  end

  describe("explicit slice ownership") do
    test "EscapeAction writes to the counter slice that declares its route" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.new()

      {:ok, agent, _dirs} =
        Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.cmd(
          agent,
          Aikido.Dsl.SlicePathResolutionTest.EscapeAction
        )

      assert agent.state.counter[:tagged] == true
      assert agent.state.domain == %{last_action: nil}
    end

    test "the compiled mount table records explicit ownership" do
      paths =
        Aikido.Dsl.Agent.Info.slice_paths_for_action(
          Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent
        )

      assert paths[Aikido.Dsl.SlicePathResolutionTest.EscapeAction] == [:counter]
    end
  end

  describe("fall back to agent's own path") do
    test "UnboundAction (no slice routes, no own path) writes to the agent's :domain slice" do
      agent = Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.new()

      {:ok, agent, _dirs} =
        Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent.cmd(
          agent,
          Aikido.Dsl.SlicePathResolutionTest.UnboundAction
        )

      assert agent.state.domain[:stamped] == true
      assert agent.state.counter == %{count: 0}
    end
  end

  describe("compile-time lookup table shape") do
    test "slice_paths_for_action maps each slice action module to a list of mount paths" do
      table =
        Aikido.Dsl.Agent.Info.slice_paths_for_action(
          Aikido.Dsl.SlicePathResolutionTest.ResolutionAgent
        )

      assert is_map(table)
      assert Map.get(table, Aikido.Dsl.SlicePathResolutionTest.BumpAction) == [:counter]
      assert table[Aikido.Dsl.SlicePathResolutionTest.EscapeAction] == [:counter]
      refute Map.has_key?(table, Aikido.Dsl.SlicePathResolutionTest.UnboundAction)
    end
  end
end
