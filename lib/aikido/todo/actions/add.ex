defmodule Aikido.Todo.Actions.Add do
  @moduledoc "Adds a todo, emits its change, and describes an optional expiration deadline."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    data = input.arguments
    state = data.state

    if Items.find(input) do
      {:error, "Todo ID already exists"}
    else
      revision = state.revision + 1

      item = %{
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

      effects =
        if data[:timeout_ms] do
          [
            Aikido.Directives.schedule(data.timeout_ms, %Aikido.Signal{
              id: nil,
              type: "aikido.todo.expire",
              data: %{id: data.id, revision: revision},
              source: "/aikido"
            })
          ]
        else
          []
        end

      Items.append(input, item, effects)
    end
  end
end
