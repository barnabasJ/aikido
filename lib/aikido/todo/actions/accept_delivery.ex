defmodule Aikido.Todo.Actions.AcceptDelivery do
  @moduledoc "Adds an incoming AI delivery's work item to its configured Todo mount."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    if input.arguments[:todo] && receives_delivered_work?(input.context.aikido) do
      append_delivered_item(input)
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end

  defp receives_delivered_work?(runtime) do
    runtime.agent_module
    |> Aikido.Agent.Info.slice_instances()
    |> Enum.any?(fn instance ->
      instance.module == Aikido.AiReact.Slice &&
        runtime.agent.state[instance.path].options.todo_path == runtime.slice_path
    end)
  end

  defp append_delivered_item(input) do
    item = input.arguments.todo
    todos = input.arguments.state

    if Enum.any?(todos.items, &(&1.id == item.id)) do
      {:error, {:todo_exists, item.id}}
    else
      item = %{item | revision: todos.revision + 1}
      Items.append(input, item, Items.expiration_directives(item))
    end
  end
end
