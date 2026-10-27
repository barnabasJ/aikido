defmodule AgentExamplesWeb.Components.Worker do
  @moduledoc "Reusable worker controls and their LiveView mount hook."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components, only: [flow: 1]
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :worker_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("work", %{"text" => text}, socket),
    do: ExamplePage.command(socket, :run, %{text: text})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def worker(assigns) do
    ~H"""
    <section class="panel">
      <.section_heading>
        <:title>Background work</:title>
        <span id="worker-status">{own(@run)[:status] || :idle}</span>
      </.section_heading>
      <.flow steps={["Dispatch", "Uppercase task", "Result signal"]} />
      <div id="worker-result" class="result-display">
        {own(@run)[:result] || "Your result will land here."}
      </div>
      <form id="worker-form" phx-submit="work">
        <label>Text to transform<input name="text" value="signals carry results" required /></label><button
          class="button primary"
          disabled={!active?(@run)}
        >Dispatch task →</button>
      </form>
    </section>
    """
  end
end
