defmodule AgentExamplesWeb.ResilienceLive do
  @moduledoc "Isolated deadline, cancellation, retry and loop guard controls."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "resilience"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("scenario", %{"query" => query}, socket)
      when query in ["retry", "wait", "cycle", "errors"],
      do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section :if={active?(@run)} class="panel" id="resilience-controls">
        <h2>Choose a failure scenario</h2>
        <button
          :for={query <- ["retry", "wait", "cycle", "errors"]}
          id={"scenario-#{query}"}
          class="button secondary"
          phx-click="scenario"
          phx-value-query={query}
        >{query}</button>
        <button id="cancel-run" class="button danger" phx-click="cancel_run">Cancel pending attempt</button>
        <p>Failing tool batches: {Map.get(@run.snapshot.ai, :tool_error_streak, 0)}</p>
      </section>
      <.conversation run={@run} prompt="cycle" />
    </.page>
    """
  end
end
