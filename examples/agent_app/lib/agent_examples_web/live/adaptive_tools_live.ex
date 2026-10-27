defmodule AgentExamplesWeb.AdaptiveToolsLive do
  @moduledoc "Native tool preparation and refresh controls."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.ToolRefresh, only: [tool_refresh: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "adaptive-tools"})
  on_mount({AgentExamplesWeb.Components.ToolRefresh, :default})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.tool_refresh run={@run} />
      <.conversation run={@run} queue_messages prompt="Show the prepared tools" />
    </.page>
    """
  end
end
