defmodule Aikido.Todo.Signals.TodoRemove do
  @moduledoc "Typed payload for `aikido.todo.remove`."
  use Aikido.Signal

  signal do
    type "aikido.todo.remove"

    schema do
      attribute :id, :string do
        description "Stable identifier of the work item targeted by this event."
        allow_nil? false
      end
    end
  end
end
