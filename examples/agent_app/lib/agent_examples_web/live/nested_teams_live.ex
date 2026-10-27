defmodule AgentExamplesWeb.NestedTeamsLive do
  @moduledoc "Interactive nested teams example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.NestedTeams, only: [nested_teams: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "nested-teams"})
  on_mount({AgentExamplesWeb.TeamTree, :default})
  on_mount({AgentExamplesWeb.Components.NestedTeams, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.nested_teams
        run={@run}
        team_trees={@team_trees}
        tree_parent={@tree_parent}
        tree_kind={@tree_kind}
        tree_name={@tree_name}
      />
    </.page>
    """
  end
end
