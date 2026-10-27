defmodule Aikido.Team.Actions.EnsureMember do
  @moduledoc "Activates a known member and its prerequisites, clearing its intentional pause."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)
    ActionAdapter.to_action_result(activate_member(signal, state, context, config))
  end

  def activate_member(signal, state, context, config) do
    TopologyOperation.begin_topology_change(signal, state, context, config, fn ->
      plan_member_activation(signal.data, state, config)
    end)
  end

  defp plan_member_activation(data, state, _config) do
    if Map.has_key?(state.topology.nodes, data.member) do
      {:ok, state.topology, [], [data.member], Map.delete(state.paused, data.member)}
    else
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :member,
         message:
           "Unknown team member #{inspect(data.member)}. " <>
             "Inspect the roster or add the member before activating it."
       )}
    end
  end
end
