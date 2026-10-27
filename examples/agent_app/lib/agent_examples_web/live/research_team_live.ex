defmodule AgentExamplesWeb.ResearchTeamLive do
  @moduledoc "Interactive research-team example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "research-team"})
  on_mount({AgentExamplesWeb.Components.Conversation, :queue})
  on_mount({AgentExamplesWeb.TeamTree, :default})

  defp default_task do
    "Design a reliable order-processing workflow using agents. Split architecture, failure recovery, and verification across specialist teams; have them delegate focused subproblems, then combine their findings into a concrete proposal with trade-offs."
  end

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.team_topology tree_states={@team_trees} run={@run} orchestrator />
      <.conversation
        run={@run}
        queue_messages
        prompt={if @mode == "offline", do: "orchestrate: " <> default_task(), else: default_task()}
      />
    </.page>
    """
  end
end
