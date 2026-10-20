defmodule Aikido.Signals.Todo.TodoRemove do
  @moduledoc "Typed payload for `aikido.todo.remove`."
  use Aikido.Signal

  signal do
    type "aikido.todo.remove"

    schema do
      attribute :id, :string, allow_nil?: false
    end
  end
end
