defmodule AgentExamplesWeb.Components.ToolRefresh do
  @moduledoc "Reusable tool refresh panel and command mount hook."
  use Phoenix.Component
  import Phoenix.LiveView
  alias AgentExamplesWeb.ExamplePage
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :tool_refresh_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("refresh", %{"set" => set}, socket) when set in ["analysis", "stamp"],
    do:
      ExamplePage.command(socket, :refresh_tools, %{
        tool_context: %{context: %{tool_set: set, stamp_label: "refreshed"}}
      })

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def tool_refresh(assigns) do
    ~H"""
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
    """
  end
end
