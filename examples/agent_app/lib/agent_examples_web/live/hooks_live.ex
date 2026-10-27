defmodule AgentExamplesWeb.HooksLive do
  @moduledoc "Interactive hooks example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.HookContext, only: [hook_context: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "hooks"})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} />
      <:inspector>
        <.hook_context run={@run} />
      </:inspector>
    </.page>
    """
  end
end
