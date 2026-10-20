defmodule Aikido.Signals.Todo.TodoActivate do
  @moduledoc "Typed payload for `aikido.todo.activate`."
  use Aikido.Signal

  signal do
    type "aikido.todo.activate"

    schema do
      attribute :id, :string, allow_nil?: false
    end
  end
end
