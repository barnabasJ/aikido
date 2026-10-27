defmodule AgentExamplesWeb.Components.Counter do
  @moduledoc "Reusable counter controls and their LiveView mount hook."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [amount_command: 1, section_heading: 1]
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :counter_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("add", %{"amount" => amount}, socket),
    do: ExamplePage.command(socket, :add, %{amount: amount})

  defp handle_event("increase", %{"amount" => amount}, socket),
    do: ExamplePage.command(socket, :increase, %{amount: amount})

  defp handle_event("decrease", %{"amount" => amount}, socket),
    do: ExamplePage.command(socket, :decrease, %{amount: amount})

  defp handle_event("counter_notice", _, socket), do: ExamplePage.command(socket, :notice, %{})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def counter(assigns) do
    ~H"""
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
      <.amount_command
        id="counter-form"
        event="add"
        label="Amount"
        value={1}
        button_text="Add →"
        button_class="button primary"
        disabled={!active?(@run)}
      />
      <.section_heading level={3}>
        <:title>Shared typed handler</:title><span>Increase or decrease</span>
      </.section_heading>
      <p>Both signals reach one action. Its typed union identifies the adjustment.</p>
      <.amount_command
        id="counter-increase-form"
        event="increase"
        label="Increase by"
        value={2}
        button_text="Increase →"
        button_class="button secondary"
        disabled={!active?(@run)}
      />
      <.amount_command
        id="counter-decrease-form"
        event="decrease"
        label="Decrease by"
        value={1}
        button_text="Decrease →"
        button_class="button secondary"
        disabled={!active?(@run)}
      />
      <.section_heading level={3}>
        <:title>Every signal counts</:title><span id="signals-seen">{own(@run)[:signals_seen] || 0} signals observed</span>
      </.section_heading>
      <p>The wildcard handler also counts notices that leave the current count unchanged.</p>
      <button
        id="counter-notice"
        class="button secondary"
        phx-click="counter_notice"
        disabled={!active?(@run)}
      >Send a notice</button>
    </section>
    """
  end
end
