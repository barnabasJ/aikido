defmodule AgentExamplesWeb.ResearcherLive do
  @moduledoc "Interactive researcher example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "researcher"})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} />
    </.page>
    """
  end
end
