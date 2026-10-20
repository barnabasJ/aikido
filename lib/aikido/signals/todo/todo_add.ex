defmodule Aikido.Signals.Todo.TodoAdd do
  @moduledoc "Typed payload for `aikido.todo.add`."
  use Aikido.Signal

  signal do
    type "aikido.todo.add"

    schema do
      attribute :id, :string, allow_nil?: false

      attribute :text, :string, allow_nil?: false

      attribute :metadata, :map, default: %{}

      attribute :blocking?, :boolean, default: true

      attribute :timeout_ms, :integer, constraints: [min: 1]
    end
  end
end
