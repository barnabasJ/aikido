defmodule AgentExamplesWeb.ResearchTeamLive do
  @moduledoc "Interactive research-team example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "research-team"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  defp default_task do
    "Design a reliable order-processing workflow using agents. Split architecture, failure recovery, and verification across specialist teams; have them delegate focused subproblems, then combine their findings into a concrete proposal with trade-offs."
  end

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.team_topology run={@run} orchestrator />
      <.conversation
        run={@run}
        prompt={if @mode == "offline", do: "orchestrate: " <> default_task(), else: default_task()}
      />
    </.page>
    """
  end
end
