defmodule Aikido.Team.Actions.RetireWorker do
  @moduledoc "Stops an idle task-scoped worker after the team has recorded its result."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Aikido.Team.ActionAdapter.unpack_team_action(input)

    result =
      if !match?(%{status: :running}, state.operation) &&
           Aikido.Team.TaskWorkerLifecycle.eligible?(state, signal.data.member) do
        Aikido.Team.Actions.StopMember.pause_member_and_descendants(
          signal,
          state,
          context,
          config
        )
      else
        {:ok, state, []}
      end

    Aikido.Team.ActionAdapter.to_action_result(result, state)
  end
end
