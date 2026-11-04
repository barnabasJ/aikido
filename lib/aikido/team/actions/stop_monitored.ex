defmodule Aikido.Team.Actions.StopMonitored do
  @moduledoc "Adopts an installed stop monitor before requesting receiving cleanup."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, MemberStop}

  @impl true
  def run(input, _, _) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    signal.data
    |> MemberStop.monitored(state, context, config)
    |> ActionAdapter.to_action_result(state, context)
  end
end
