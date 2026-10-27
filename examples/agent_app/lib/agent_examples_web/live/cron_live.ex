defmodule AgentExamplesWeb.CronLive do
  @moduledoc "Recurring signals with start, cancellation and live tick counts."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  on_mount({AgentExamplesWeb.ExamplePage, "cron"})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel" id="cron-clock">
        <h2>Recurring clock</h2>
        <p><strong id="cron-count">{own(@run)[:count] || 0}</strong> ticks received</p>
        <p>Every two seconds · UTC · <code>*/2 * * * * * *</code></p>
        <p id="cron-status">{if own(@run)[:enabled], do: "Running", else: "Paused"}</p>
        <button
          id="enable-cron"
          class="button primary"
          phx-click="enable_cron"
          disabled={!active?(@run) || own(@run)[:enabled]}
        >Start clock</button>
        <button
          id="disable-cron"
          class="button secondary"
          phx-click="disable_cron"
          disabled={!active?(@run) || !own(@run)[:enabled]}
        >Pause clock</button>
      </section>
    </.page>
    """
  end

  def handle_event("enable_cron", _, socket) do
    {:halt, socket} = AgentExamplesWeb.ExamplePage.command(socket, :enable, %{})
    {:noreply, socket}
  end

  def handle_event("disable_cron", _, socket) do
    {:halt, socket} = AgentExamplesWeb.ExamplePage.command(socket, :disable, %{})
    {:noreply, socket}
  end
end
