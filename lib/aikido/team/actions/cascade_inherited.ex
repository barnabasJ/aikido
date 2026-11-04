defmodule Aikido.Team.Actions.CascadeInherited do
  @moduledoc "Acknowledge inherited configuration only after this team's running children settle it."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _options, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    if Map.get(config, :reconcile_inherit, []) == [] do
      Aikido.Types.ActionResult.new(changes: nil)
    else
      reply = %{
        pid: context.__delivery__.sender.pid,
        operation_id: signal.data.operation_id,
        member: signal.data.member
      }

      TopologyOperation.reconcile_inherited(signal, state, context, config, reply)
      |> ActionAdapter.to_action_result(state, context)
    end
  end
end
