defmodule AgentExamplesWeb.ConversationLive do
  @moduledoc "Interactive conversation example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.Todos, only: [todos: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "conversation"})
  on_mount({AgentExamplesWeb.Components.Todos, :default})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} queue_messages />
      <.todos run={@run} />
    </.page>
    """
  end
end
