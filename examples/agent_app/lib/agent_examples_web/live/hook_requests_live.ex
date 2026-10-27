defmodule AgentExamplesWeb.HookRequestsLive do
  @moduledoc "Interactive hook-requests example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.HookContext, only: [hook_context: 1]
  import AgentExamplesWeb.Components.InteractionRequests, only: [interaction_requests: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "hook-requests"})
  on_mount({AgentExamplesWeb.Components.InteractionRequests, :default})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run}>
        <.interaction_requests run={@run} />
      </.conversation>
      <:inspector>
        <.hook_context run={@run} />
      </:inspector>
    </.page>
    """
  end
end
