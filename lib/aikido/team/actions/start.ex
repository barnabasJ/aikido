defmodule Aikido.Team.Actions.Start do
  @moduledoc "Builds the desired team topology and begins ordered member activation."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      configure_topology_and_activate(signal, state, context, config),
      state
    )
  end

  defp configure_topology_and_activate(signal, state, context, config) do
    TopologyOperation.begin_topology_change(signal, state, context, config, fn ->
      plan_topology_replacement(signal.data, state, config)
    end)
  end

  defp plan_topology_replacement(data, state, config) do
    with {:ok, next} <-
           Topology.build(
             data[:topology] || state.topology.nodes,
             config.instance,
             config.max_members
           ) do
      changed =
        for {name, spec} <- state.topology.nodes, Map.get(next.nodes, name) != spec, do: name

      affected = Topology.members_with_dependents(state.topology, changed)

      retained =
        Enum.filter(
          affected,
          &(Map.has_key?(state.members, &1) && Map.has_key?(next.nodes, &1))
        )

      {:ok, next, affected, Enum.uniq(Topology.eager(next) ++ retained), %{}}
    end
  end
end
