defmodule AgentExamplesWeb.Components.Resilience do
  @moduledoc "Reusable resilience panel and command mount hook."
  use Phoenix.Component
  import Phoenix.LiveView
  alias AgentExamplesWeb.ExamplePage
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :resilience_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("scenario", %{"query" => query}, socket)
       when query in ["retry", "wait", "cycle", "errors"],
       do: ExamplePage.command(socket, :ask, %{query: query})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def resilience(assigns) do
    ~H"""
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
    """
  end
end
