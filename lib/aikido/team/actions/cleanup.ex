defmodule Aikido.Team.Actions.Cleanup do
  @moduledoc "Records the native cleanup result of an exact pending late activation."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, MemberStop}

  @impl true
  def run(input, _, _) do
    {signal, state, context, _config} = ActionAdapter.unpack_team_action(input)

    signal.data
    |> MemberStop.cleanup_result(state)
    |> ActionAdapter.to_action_result(state, context)
  end
end
