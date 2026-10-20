defmodule AgentExamplesWeb.HooksLive do
  @moduledoc "Interactive hooks example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "hooks"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} />
      <:inspector>
        <section class="panel" id="hook-inspector">
          <h2>Hook context</h2>
          <p class="muted">
            Synchronous hooks finish before the next step. Async context enters the next eligible model request.
          </p>
          <ol id="hook-context">
            <li :for={text <- if(@run, do: Map.get(@run.snapshot.ai, :hook_messages, []), else: [])}>
              {text}
            </li>
          </ol>
          <p
            :for={error <- if(@run, do: Map.get(@run.snapshot.ai, :hook_errors, []), else: [])}
            class="error"
          >
            {inspect(error)}
          </p>
        </section>
      </:inspector>
    </.page>
    """
  end
end
