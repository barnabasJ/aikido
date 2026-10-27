defmodule AgentExamplesWeb.VerifiedTeamLive do
  @moduledoc "Background work and native verification in one scoped team run."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "verified-team"})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})
  on_mount({AgentExamplesWeb.TeamTree, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.team_topology tree_states={@team_trees} run={@run} orchestrator />
      <.conversation run={@run} prompt="Delegate an evidence check in background mode, then explain how the result reaches the lead." />
    </.page>
    """
  end
end
