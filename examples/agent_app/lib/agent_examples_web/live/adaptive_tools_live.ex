defmodule AgentExamplesWeb.AdaptiveToolsLive do
  @moduledoc "Native tool preparation and refresh controls."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "adaptive-tools"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("refresh", %{"set" => set}, socket) when set in ["analysis", "stamp"],
    do:
      ExamplePage.command(socket, :refresh_tools, %{
        tool_context: %{context: %{tool_set: set, stamp_label: "refreshed"}}
      })

  def handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section :if={active?(@run)} class="panel" id="tool-refresh">
        <h2>Application tool context</h2>
        <button class="button secondary" phx-click="refresh" phx-value-set="analysis">Analysis tools</button>
        <button class="button secondary" phx-click="refresh" phx-value-set="stamp">Stamp tools</button>
        <p>
          Setup generation: {Map.get(@run.snapshot.ai, :tools_generation, 0)} · Refresh pending: {Map.get(
            @run.snapshot.ai,
            :tool_refresh_pending,
            false
          )}
        </p>
        <button class="button danger" phx-click="cancel_run">Cancel pending work</button>
      </section>
      <.conversation run={@run} queue_messages prompt="Show the prepared tools" />
    </.page>
    """
  end
end
