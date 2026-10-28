defmodule Aikido.Team.Actions.Reconcile do
  @moduledoc "Restarts requested members and activates eager members while respecting paused members."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      reconcile_member_activation(signal, state, context, config),
      state
    )
  end

  defp reconcile_member_activation(signal, state, context, config) do
    TopologyOperation.begin_topology_change(signal, state, context, config, fn ->
      plan_reconciliation(signal.data, state, config)
    end)
  end

  defp plan_reconciliation(data, state, _config) do
    requested = Enum.uniq(Topology.eager(state.topology) ++ Map.get(data, :members, []))

    {:ok, state.topology, Map.get(data, :replace, []),
     Enum.reject(requested, &Map.has_key?(state.paused, &1)), state.paused}
  end
end
