defmodule Aikido.Team.Actions.StopMember do
  @moduledoc "Stops a member and its descendants while retaining their paused topology entries."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      pause_member_and_descendants(signal, state, context, config),
      state
    )
  end

  @doc "Plan a paused member subtree and request its process stops. Performs no I/O."
  def pause_member_and_descendants(signal, state, context, config) do
    TopologyOperation.begin_topology_change(signal, state, context, config, fn ->
      plan_member_stop(signal.data, state, config)
    end)
  end

  defp plan_member_stop(data, state, _config) do
    with {:ok, _next, stopped} <- Topology.remove(state.topology, data.member, true) do
      {:ok, state.topology, stopped, [], Map.merge(state.paused, Map.new(stopped, &{&1, true}))}
    end
  end
end
