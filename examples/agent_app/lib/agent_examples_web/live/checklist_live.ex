defmodule AgentExamplesWeb.ChecklistLive do
  @moduledoc "Interactive checklist example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "checklist"})

  def handle_event("add_item", %{"item" => item}, socket),
    do: ExamplePage.command(socket, :add, %{item: item})

  def handle_event("complete", %{"item" => item}, socket),
    do: ExamplePage.command(socket, :complete, %{item: item})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel">
        <div class="section-heading">
          <h2>Checklist</h2><span id="completed-count">{own(@run)[:completed] || 0} completed</span>
        </div>
        <div class="progress-track">
          <div style={"width: #{if ((own(@run)[:completed] || 0) + length(own(@run)[:items] || [])) == 0, do: 0, else: round((own(@run)[:completed] || 0) / ((own(@run)[:completed] || 0) + length(own(@run)[:items] || [])) * 100)}%"}>
          </div>
        </div>
        <ul id="checklist" class="checklist">
          <li :for={item <- own(@run)[:items] || []}>
            <span>{item}</span><button
              phx-click="complete"
              phx-value-item={item}
              class="text-button"
            >Complete ✓</button>
          </li>
        </ul>
        <form id="checklist-form" phx-submit="add_item" class="inline-form">
          <label>New item<input name="item" placeholder="Try this example" required /></label><button
            class="button primary"
            disabled={!active?(@run)}
          >Add item</button>
        </form>
      </section>
    </.page>
    """
  end
end
