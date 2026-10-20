defmodule AgentExamplesWeb.ConversationLive do
  @moduledoc "Interactive conversation example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "conversation"})

  def handle_event("ask", %{"query" => query}, socket),
    do: ExamplePage.command(socket, :ask, %{query: query})

  def handle_event("todo_add", %{"text" => text}, socket),
    do: ExamplePage.command(socket, :todo_add, %{id: Ash.UUIDv7.generate(), text: text})

  def handle_event("todo_complete", %{"id" => id}, socket),
    do:
      ExamplePage.command(socket, :todo_complete, %{id: id, result: "Verified in the playground"})

  def handle_event("todo_block", %{"id" => id}, socket),
    do: ExamplePage.command(socket, :todo_block, %{id: id, reason: "Blocked in the playground"})

  def handle_event("todo_remove", %{"id" => id}, socket),
    do: ExamplePage.command(socket, :todo_remove, %{id: id})

  def handle_event("cancel_run", _, socket), do: ExamplePage.command(socket, :cancel, %{})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.conversation run={@run} queue_messages />
      <section :if={active?(@run)} class="panel" id="todos">
        <h2>Optional todos</h2>
        <p>Completion waits for blocking items. Record evidence, block an item, or remove it.</p>
        <form id="todo-form" phx-submit="todo_add" class="inline-form">
          <input name="text" placeholder="Work to verify" required />
          <button class="button secondary">Add todo</button>
        </form>
        <article :for={item <- @run.snapshot.todos} id={"todo-#{item.id}"}>
          <span>{item.text} · {item.status}</span>
          <button class="button secondary" phx-click="todo_complete" phx-value-id={item.id}>Complete</button>
          <button class="button secondary" phx-click="todo_block" phx-value-id={item.id}>Block</button>
          <button class="button secondary" phx-click="todo_remove" phx-value-id={item.id}>Remove</button>
        </article>
      </section>
    </.page>
    """
  end
end
