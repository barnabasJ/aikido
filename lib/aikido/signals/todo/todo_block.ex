defmodule Aikido.Signals.Todo.TodoBlock do
  @moduledoc "Typed payload for `aikido.todo.block`."
  use Aikido.Signal

  signal do
    type "aikido.todo.block"

    schema do
      attribute :id, :string, allow_nil?: false

      attribute :reason, :term, allow_nil?: false
    end
  end
end
