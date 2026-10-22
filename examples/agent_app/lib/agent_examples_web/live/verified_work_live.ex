defmodule AgentExamplesWeb.VerifiedWorkLive do
  @moduledoc "Atomic task delivery and native evidence verification."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "verified-work"})

  def handle_event("deliver", _, socket),
    do:
      ExamplePage.command(socket, :deliver, %{
        text: "Complete delivered-work with evidence",
        request_id: Ash.UUIDv7.generate(),
        todo: %{id: "delivered-work", text: "Check the delivered task", blocking?: true}
      })

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <section :if={active?(@run)} class="panel" id="verified-work">
        <h2>Work and evidence</h2>
        <button id="deliver-work" class="button primary" phx-click="deliver">Deliver task + todo</button>
        <button class="button danger" phx-click="cancel_run">Cancel</button>
        <p>
          Continuations: {Map.get(@run.snapshot.ai, :todo_continuations, 0)} · Verifying: {Map.get(
            @run.snapshot.ai,
            :todo_verification_pending,
            false
          )}
        </p>
        <article :for={item <- @run.snapshot.todos} id={"todo-#{item.id}"}>
          {item.text} · {item.status}<pre>{inspect(item.result)}</pre>
        </article>
        <pre id="verified-answer">{Map.get(@run.snapshot.ai, :result)}</pre>
      </section>
      <.conversation run={@run} />
    </.page>
    """
  end
end
