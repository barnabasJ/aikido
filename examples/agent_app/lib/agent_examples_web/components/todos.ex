defmodule AgentExamplesWeb.Components.Todos do
  @moduledoc "Reusable todos panel and command mount hook."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [todo_item: 1]
  import Phoenix.LiveView
  alias AgentExamplesWeb.ExamplePage
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :todos_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("todo_add", %{"text" => text}, socket),
    do: ExamplePage.command(socket, :todo_add, %{id: Ash.UUIDv7.generate(), text: text})

  defp handle_event("todo_complete", %{"id" => id}, socket),
    do:
      ExamplePage.command(socket, :todo_complete, %{id: id, result: "Verified in the playground"})

  defp handle_event("todo_block", %{"id" => id}, socket),
    do: ExamplePage.command(socket, :todo_block, %{id: id, reason: "Blocked in the playground"})

  defp handle_event("todo_remove", %{"id" => id}, socket),
    do: ExamplePage.command(socket, :todo_remove, %{id: id})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def todos(assigns) do
    ~H"""
    <section :if={active?(@run)} class="panel" id="todos">
      <h2>Optional todos</h2>
      <p>Completion waits for blocking items. Record evidence, block an item, or remove it.</p>
      <form id="todo-form" phx-submit="todo_add" class="inline-form">
        <input name="text" placeholder="Work to verify" required />
        <button class="button secondary">Add todo</button>
      </form>
      <.todo_item :for={item <- @run.snapshot.todos} item={item} controls />
    </section>
    """
  end
end
