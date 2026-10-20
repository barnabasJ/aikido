defmodule AgentExamplesWeb.CounterLive do
  @moduledoc "Interactive counter example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "counter"})

  def handle_event("add", %{"amount" => amount}, socket),
    do: ExamplePage.command(socket, :add, %{amount: amount})

  def handle_event("increase", %{"amount" => amount}, socket),
    do: ExamplePage.command(socket, :increase, %{amount: amount})

  def handle_event("decrease", %{"amount" => amount}, socket),
    do: ExamplePage.command(socket, :decrease, %{amount: amount})

  def handle_event("counter_notice", _, socket), do: ExamplePage.command(socket, :notice, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel" id="counter-panel">
        <div class="counter-visual">
          <svg viewBox="0 0 160 160" role="img" aria-label="Counter state"><circle
            cx="80"
            cy="80"
            r="68"
            class="ring-track"
          /><circle
            cx="80"
            cy="80"
            r="68"
            class="ring-value"
            stroke-dasharray={"#{min(abs(own(@run)[:count] || 0), 100) * 4.27} 427"}
          /></svg><div>
            <strong id="counter-value">{own(@run)[:count] || 0}</strong><span>current count</span>
          </div>
        </div>
        <form id="counter-form" phx-submit="add" class="inline-form">
          <label>Amount<input type="number" name="amount" value="1" /></label><button
            class="button primary"
            disabled={!active?(@run)}
          >Add →</button>
        </form>
        <div class="section-heading">
          <h3>Shared typed handler</h3><span>Increase or decrease</span>
        </div>
        <p>Both signals reach one action. Its typed union identifies the adjustment.</p>
        <form id="counter-increase-form" phx-submit="increase" class="inline-form">
          <label>Increase by<input type="number" name="amount" value="2" /></label>
          <button class="button secondary" disabled={!active?(@run)}>Increase →</button>
        </form>
        <form id="counter-decrease-form" phx-submit="decrease" class="inline-form">
          <label>Decrease by<input type="number" name="amount" value="1" /></label>
          <button class="button secondary" disabled={!active?(@run)}>Decrease →</button>
        </form>
        <div class="section-heading">
          <h3>Every signal counts</h3>
          <span id="signals-seen">{own(@run)[:signals_seen] || 0} signals observed</span>
        </div>
        <p>The wildcard handler also counts notices that leave the current count unchanged.</p>
        <button
          id="counter-notice"
          class="button secondary"
          phx-click="counter_notice"
          disabled={!active?(@run)}
        >Send a notice</button>
      </section>
    </.page>
    """
  end
end
