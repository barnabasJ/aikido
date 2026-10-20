defmodule AgentExamplesWeb.NotebookLive do
  @moduledoc "Interactive notebook example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "notebook"})

  def handle_event("append", %{"text" => text}, socket),
    do: ExamplePage.command(socket, :append, %{text: text})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section class="panel">
        <div class="section-heading">
          <h2>{own(@run)[:title] || "Notebook"}</h2><span>Embedded journal slice</span>
        </div>
        <div id="journal" class="journal">
          <article :for={
            {entry, index} <- Enum.with_index(if(@run, do: @run.snapshot.journal, else: []))
          }>
            <span>NOTE {index + 1}</span><p>{entry}</p>
          </article>
        </div>
        <form id="notebook-form" phx-submit="append">
          <label>Journal entry<textarea
            name="text"
            rows="3"
            placeholder="What did you discover?"
            required
          ></textarea></label><button class="button primary" disabled={!active?(@run)}>Append note →</button>
        </form>
      </section>
    </.page>
    """
  end
end
