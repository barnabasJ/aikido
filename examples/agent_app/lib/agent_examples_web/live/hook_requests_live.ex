defmodule AgentExamplesWeb.HookRequestsLive do
  @moduledoc "Interactive hook-requests example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "hook-requests"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("respond", %{"id" => id, "choice" => choice}, socket) do
    requests =
      if socket.assigns.run,
        do: socket.assigns.run.requests,
        else: []

    request = Enum.find(requests, &(&1.id == id))

    if request && choice in Map.get(request.payload, "choices", []) do
      ExamplePage.command(socket, :respond, %{interaction_id: id, response: %{choice: choice}})
    else
      {:noreply, assign(socket, error: "This request is no longer available.")}
    end
  end

  def handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run}>
        <section :if={active?(@run)} id="hook-requests">
          <article
            :for={request <- @run.requests}
            id={"request-#{request.id}"}
            class="panel"
          >
            <h3>{Map.get(request.payload, "title", request.type)}</h3>
            <pre>{inspect(Map.get(request.payload, "details", request.payload), pretty: true)}</pre>
            <div class="inline-form">
              <button
                :for={choice <- Map.get(request.payload, "choices", [])}
                class="button secondary"
                phx-click="respond"
                phx-value-id={request.id}
                phx-value-choice={choice}
              >{choice}</button>
              <button class="button danger" phx-click="cancel_run">Cancel run</button>
            </div>
          </article>
        </section>
      </.conversation>
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
