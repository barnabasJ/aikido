defmodule Aikido.Todo.Signals.TodoActivate do
  @moduledoc "Typed payload for `aikido.todo.activate`."
  use Aikido.Signal

  signal do
    type "aikido.todo.activate"

    schema do
      attribute :id, :string do
        description "Stable identifier of the work item targeted by this event."
        allow_nil? false
      end
    end
  end
end
