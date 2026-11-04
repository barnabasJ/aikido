defmodule Aikido.Team.Actions.Stopped do
  @moduledoc "Records receiver-prepared cleanup and waits for the matching monitored member exit."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, MemberStop}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    signal.data
    |> MemberStop.prepared(state, context, config)
    |> ActionAdapter.to_action_result(state, context)
  end
end
