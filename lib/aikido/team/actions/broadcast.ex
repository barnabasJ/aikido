defmodule Aikido.Team.Actions.Broadcast do
  @moduledoc "Returns signal delivery directives for the selected running team members."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Tasks}
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.unpack_team_action(input)
    Inputs.to_action_result(build_member_deliveries(signal.data, state, context, config))
  end

  defp build_member_deliveries(data, state, _context, _config) do
    targets = data[:members] || Map.keys(state.members)

    with {:ok, pids} <-
           Enum.reduce_while(targets, {:ok, []}, fn name, {:ok, pids} ->
             case Tasks.fetch_running_member_pid(state, name) do
               {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
               error -> {:halt, error}
             end
           end) do
      signal =
        %Signal{id: nil, type: data.type, data: Map.get(data, :payload, %{}), source: "/ash/team"}

      {:ok, state, Enum.map(pids, &Directives.emit_to_pid(signal, &1))}
    end
  end
end
