defmodule Aikido.Team.Actions.Send do
  @moduledoc "Returns a signal delivery directive for one running team member."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.ActionAdapter
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      build_member_delivery(signal.data, state, context, config),
      state
    )
  end

  defp build_member_delivery(data, state, context, _config) do
    with {:ok, pid} <- Aikido.Team.MemberProcesses.fetch_running_member_pid(state, data.member) do
      signal =
        %Signal{id: nil, type: data.type, data: Map.get(data, :payload, %{}), source: "/ash/team"}

      {:ok, state, [Aikido.Team.Delivery.directive(signal, pid, :message, context)]}
    end
  end
end
