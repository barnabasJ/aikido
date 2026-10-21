defmodule Aikido.Todo.Signals.TodoComplete do
  @moduledoc "Typed payload for `aikido.todo.complete`."
  use Aikido.Signal

  signal do
    type "aikido.todo.complete"

    schema do
      attribute :id, :string do
        description "Stable identifier of the work item targeted by this event."
        allow_nil? false
      end

      attribute :result, :term do
        description "Explicit completion evidence to retain on the completed item."
      end
    end
  end
end
