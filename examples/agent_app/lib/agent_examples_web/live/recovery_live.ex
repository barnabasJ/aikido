defmodule AgentExamplesWeb.RecoveryLive do
  @moduledoc "Permanent conversation recovery using the same domain start and stop commands."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.Recovery, only: [recovery: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "recovery"})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.recovery run={@run} />
      <.conversation run={@run} queue_messages prompt="Remember this before stopping" />
    </.page>
    """
  end
end
