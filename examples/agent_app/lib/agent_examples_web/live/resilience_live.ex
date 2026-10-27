defmodule AgentExamplesWeb.ResilienceLive do
  @moduledoc "Isolated deadline, cancellation, retry and loop guard controls."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.Resilience, only: [resilience: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "resilience"})
  on_mount({AgentExamplesWeb.Components.Resilience, :default})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.resilience run={@run} />
      <.conversation run={@run} prompt="cycle" />
    </.page>
    """
  end
end
