defmodule Aikido.Dsl.SlicePathResolutionTest do
  @moduledoc "Targeted coverage for the `__resolve_slice_paths__/1` resolution\norder:\n\n  1. Every mount that routes to the action via its `signal_routes`\n     (the compile-time `:slice_paths_for_action` lookup table). Returns\n     a list — multi-instance mounts contribute multiple entries; the\n     agent's own path is appended when the agent's own `signal_routes`\n     also declares the action.\n  2. Fallback (when the table has no entry for the action): the\n     action's own `path :foo` escape valve (for ad-hoc actions on the\n     agent's own `signal_routes` that aren't owned by any slice).\n  3. Final fallback: the agent's own `path :foo` (its `agent do … end`\n     slice).\n\nSteps 2 and 3 yield a single-element list so the runtime fan-out fold\nin `__run_instruction__` is uniform across single-mount and\nmulti-mount cases.\n"
  use ExUnit.Case, async: true

  defmodule CounterSlice do
    @moduledoc false
    use Aikido.Slice

    slice do
      name("resolution_counter_slice")

      schema do
        attribute(:count, :integer, allow_nil?: false, default: 0)
      end
    end

    signal_routes do
      route("counter.bump", Aikido.Dsl.SlicePathResolutionTest.BumpAction)
    end
  end

  defmodule BumpAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "bump"}}
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
      {:ok, %{slice | count: (slice[:count] || 0) + 1}, []}
    end
  end

  defmodule EscapeAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "escape", path: :counter}}
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
      {:ok, Map.put(slice || %{count: 0}, :tagged, true), []}
    end
  end

  defmodule UnboundAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "unbound"}}
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
      {:ok, Map.put(slice || %{}, :stamped, true), []}
    end
  end

  defmodule ResolutionAgent do
    @moduledoc false
    use Aikido.Agent, default_slices: false

    agent do
      name("resolution_agent")
      path(:domain)

      schema do
        attribute(:last_action, :atom, default: nil)
      end
    end

    slices do
      slice(:counter, CounterSlice)
    end
  end

  # No agent-level signal_routes — these tests target the FALLBACK chain
  # (action's own `path :foo`, then agent's path) for actions that are
  # not declared in any slice's or the agent's signal_routes. Coverage
  # for design choice #1 ("agent-level routes contribute the agent's
  # own path to the fan-out list") lives in the multi-instance fan-out
  # test suite.
  describe("step 1 — slice that routes to the action wins") do
    test "BumpAction (in CounterSlice's signal_routes) writes to :counter, not :domain" do
      agent = ResolutionAgent.new()
      assert agent.state.counter == %{count: 0}
      {:ok, agent, _dirs} = ResolutionAgent.cmd(agent, BumpAction)
      assert agent.state.counter == %{count: 1}
      # Domain slice is untouched even though the agent declares `path :domain`.
      assert agent.state.domain == %{last_action: nil}
    end

    test "BumpAction has no `path :foo` of its own — resolution comes from the slice mount" do
      assert Map.get(Aikido.ActionRef.action_options(BumpAction), :path) == nil
    end
  end

  describe("step 2 — action's own `path :foo` escape valve") do
    test "EscapeAction (not in any slice's signal_routes) writes to its declared :counter path" do
      agent = ResolutionAgent.new()
      {:ok, agent, _dirs} = ResolutionAgent.cmd(agent, EscapeAction)
      # Action's `path :counter` overrides falling through to the agent's
      # `path :domain`, even though no slice routes to this action.
      assert agent.state.counter[:tagged] == true
      assert agent.state.domain == %{last_action: nil}
    end

    test "EscapeAction has `path :counter` declared as the escape valve" do
      assert Map.get(Aikido.ActionRef.action_options(EscapeAction), :path) == :counter
    end
  end

  describe("step 3 — fall back to agent's own path") do
    test "UnboundAction (no slice routes, no own path) writes to the agent's :domain slice" do
      agent = ResolutionAgent.new()
      {:ok, agent, _dirs} = ResolutionAgent.cmd(agent, UnboundAction)
      assert agent.state.domain[:stamped] == true
      assert agent.state.counter == %{count: 0}
    end
  end

  describe("compile-time lookup table shape") do
    test "slice_paths_for_action maps each slice action module to a list of mount paths" do
      table = Aikido.Dsl.Agent.Info.slice_paths_for_action(ResolutionAgent)
      assert is_map(table)
      # Single-mount case is a one-element list — fan-out is uniform.
      assert Map.get(table, BumpAction) == [:counter]
      # The escape-valve action and the unbound action are NOT in the table —
      # they're not routed-to from any slice's signal_routes nor declared on
      # the agent's own signal_routes.
      refute Map.has_key?(table, EscapeAction)
      refute Map.has_key?(table, UnboundAction)
    end
  end
end
