defmodule AgentExamplesWeb.WorkerLive do
  @moduledoc "Interactive worker example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.Components, only: [flow: 1]
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "worker"})

  def handle_event("work", %{"text" => text}, socket),
    do: ExamplePage.command(socket, :run, %{text: text})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel">
        <div class="section-heading">
          <h2>Background work</h2><span id="worker-status">{own(@run)[:status] || :idle}</span>
        </div>
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
    </.page>
    """
  end
end
