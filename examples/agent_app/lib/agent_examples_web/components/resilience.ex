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
       when query in ["retry", "provider", "wait", "cycle", "errors"],
       do: ExamplePage.command(socket, :ask, %{query: query})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def resilience(assigns) do
    ~H"""
    <section :if={active?(@run)} class="panel" id="resilience-controls">
      <h2>Choose a failure scenario</h2>
      <button
        :for={query <- ["retry", "provider", "wait", "cycle", "errors"]}
        id={"scenario-#{query}"}
        class="button secondary"
        phx-click="scenario"
        phx-value-query={query}
      >{query}</button>
      <button id="cancel-run" class="button danger" phx-click="cancel_run">Cancel pending attempt</button>
      <p>Failing tool batches: {Map.get(@run.snapshot.ai, :tool_error_streak, 0)}</p>
      <p>Provider opens a circuit after a synthetic stream failure, waits one second and exhausts its single retry. Attempt facts below contain no provider payload.</p>
      <.model_attempts attempts={Map.get(@run.snapshot.ai, :model_attempts, [])} />
    </section>
    """
  end

  attr :attempts, :list, required: true

  def model_attempts(assigns) do
    ~H"""
    <div class="model-attempts" id="model-attempts">
      <table>
        <thead>
          <tr><th>Turn / attempt</th><th>Mode</th><th>Phase</th><th>Budget</th><th>Wire / progress / rendered</th><th>HTTP</th></tr>
        </thead>
        <tbody>
          <tr :for={attempt <- @attempts}>
            <td>{attempt.iteration} / {attempt.attempt}</td>
            <td>{attempt.mode}</td>
            <td>{attempt.phase}</td>
            <td>{Map.get(attempt, :timeout_ms, 0)} ms</td>
            <td>{Map.get(attempt, :wire_chunks, 0)} / {Map.get(attempt, :qualifying_chunks, 0)} / {Map.get(attempt, :rendered_chunks, 0)}</td>
            <td>{Map.get(attempt, :status, "Unknown")}</td>
          </tr>
        </tbody>
      </table>
      <p :if={@attempts == []}>No model attempts yet.</p>
    </div>
    """
  end
end
