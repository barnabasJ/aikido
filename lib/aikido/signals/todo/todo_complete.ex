defmodule Aikido.Signals.Todo.TodoComplete do
  @moduledoc "Typed payload for `aikido.todo.complete`."
  use Aikido.Signal

  signal do
    type "aikido.todo.complete"

    schema do
      attribute :id, :string, allow_nil?: false

      attribute :result, :term
    end
  end
end
