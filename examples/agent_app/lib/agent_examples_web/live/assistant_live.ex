defmodule AgentExamplesWeb.AssistantLive do
  @moduledoc "Interactive assistant example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "assistant"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} />
    </.page>
    """
  end
end
