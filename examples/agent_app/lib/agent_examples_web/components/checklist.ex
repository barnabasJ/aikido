defmodule AgentExamplesWeb.Components.Checklist do
  @moduledoc "Reusable checklist controls and their LiveView mount hook."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :checklist_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("add_item", %{"item" => item}, socket),
    do: ExamplePage.command(socket, :add, %{item: item})

  defp handle_event("complete", %{"item" => item}, socket),
    do: ExamplePage.command(socket, :complete, %{item: item})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def checklist(assigns) do
    ~H"""
    <section class="panel">
      <.section_heading>
        <:title>Checklist</:title>
        <span id="completed-count">{own(@run)[:completed] || 0} completed</span>
      </.section_heading>
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
    """
  end
end
