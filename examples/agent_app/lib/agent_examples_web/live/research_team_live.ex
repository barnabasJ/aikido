defmodule AgentExamplesWeb.ResearchTeamLive do
  @moduledoc "Interactive research-team example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "research-team"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} prompt="orchestrate: Signals carry results" />
      <.team_topology run={@run} orchestrator />
    </.page>
    """
  end
end
