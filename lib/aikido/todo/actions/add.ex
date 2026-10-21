defmodule Aikido.Todo.Actions.Add do
  @moduledoc "Adds a todo, emits its change, and describes an optional expiration deadline."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    if Items.find(input) do
      {:error, "Todo ID already exists"}
    else
      item = pending_item(input.arguments, input.arguments.state.revision + 1)
      Items.append(input, item, expiration_directives(item))
    end
  end

  defp pending_item(data, revision) do
    %{
      id: data.id,
      text: data.text,
      metadata: data.metadata,
      blocking?: data.blocking?,
      status: :pending,
      result: nil,
      reason: nil,
      revision: revision,
      timeout_ms: data[:timeout_ms]
    }
  end

  defp expiration_directives(%{timeout_ms: nil}), do: []

  defp expiration_directives(item) do
    [
      Aikido.Directives.schedule(item.timeout_ms, %Aikido.Signal{
        id: nil,
        type: "aikido.todo.expire",
        data: %{id: item.id, revision: item.revision},
        source: "/aikido"
      })
    ]
  end
end
