defmodule AgentExamples.AI.Tools.Actions.TeamRoster do
  @moduledoc "Lists running teammates and worker templates from the caller's nearest team."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.TeamAccess

  @impl true
  def run(input, _opts, context) do
    with {:ok, team, _member, _caller} <- TeamAccess.resolve_caller_team(input, context) do
      members = team.team.members |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

      templates =
        Aikido.Agent.Info.team_config(team.__struct__).workers
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()

      {:ok, %{members: members, templates: templates}}
    end
  end
end
