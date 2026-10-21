defmodule Aikido.Todo.Signals.TodoChanged do
  @moduledoc "Typed payload for `aikido.todo.changed`."
  use Aikido.Signal

  signal do
    type "aikido.todo.changed"
  end
end
