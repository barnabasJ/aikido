defmodule AgentExamplesWeb.TeamLive do
  @moduledoc "Interactive team example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Team, only: [team: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "team"})
  on_mount({AgentExamplesWeb.TeamTree, :default})
  on_mount({AgentExamplesWeb.Components.Team, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.team run={@run} team_trees={@team_trees} />
    </.page>
    """
  end
end
