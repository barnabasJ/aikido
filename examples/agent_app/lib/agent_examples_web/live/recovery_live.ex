defmodule AgentExamplesWeb.RecoveryLive do
  @moduledoc "Permanent conversation recovery using the same domain start and stop commands."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "recovery"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel" id="recovery-instructions">
        <h2>Restore a conversation</h2>
        <p>
          Send a message, use Stop example, then Start example again. The ID stays the same; the PID changes. Ask again to check retained history.
        </p>
        <p :if={@run}>Current process: <code>{inspect(@run.record.pid)}</code></p>
      </section>
      <.conversation run={@run} queue_messages prompt="Remember this before stopping" />
    </.page>
    """
  end
end
