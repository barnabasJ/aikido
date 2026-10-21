defmodule Aikido.Todo.Signals.TodoBlock do
  @moduledoc "Typed payload for `aikido.todo.block`."
  use Aikido.Signal

  signal do
    type "aikido.todo.block"

    schema do
      attribute :id, :string do
        description "Stable identifier of the work item targeted by this event."
        allow_nil? false
      end

      attribute :reason, :term do
        description "Reason the work item cannot proceed."
        allow_nil? false
      end
    end
  end
end
