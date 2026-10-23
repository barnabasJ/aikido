defmodule AgentExamplesWeb.Components do
  use Phoenix.Component
  alias AgentExamples.Catalog

  attr :active, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :examples, Catalog.all())

    ~H"""
    <div class="app-shell">
      <aside class="sidebar">
        <.link navigate="/" class="brand"><span class="brand-icon">A</span>
        Aikido <span class="brand-tag">playground</span></.link>
        <.link href="/dashboard" class="nav-link" id="telemetry-dashboard-link">
          <span class="nav-dot"></span>Telemetry dashboard ↗
        </.link>
        <p class="nav-heading">EXPLORE THE EXAMPLES</p>
        <nav aria-label="Examples">
          <.link
            :for={example <- @examples}
            navigate={"/examples/#{example.slug}"}
            class={["nav-link", @active == example.slug && "active"]}
          >
            <span class="nav-dot"></span>{example.title}
          </.link>
        </nav>
        <div class="sidebar-note">
          <span class="live-dot"></span>
          Live, local, and inspectable<p>
            Real agents. Real signals.<br />A little room to experiment.
          </p>
        </div>
      </aside>
      <main class="main-content">{render_slot(@inner_block)}</main>
    </div>
    """
  end

  attr :steps, :list, required: true

  def flow(assigns) do
    ~H"""
    <div class="flow" aria-label="How this example works">
      <div :for={{step, index} <- Enum.with_index(@steps)} class="flow-step">
        <span class="step-number">{index + 1}</span><span>{step}</span>
      </div>
    </div>
    """
  end
end
