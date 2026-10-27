defmodule Aikido.Todo.Signals.Expire do
  @moduledoc "Typed payload for `aikido.todo.expire`."
  use Aikido.Signal

  signal do
    type "aikido.todo.expire"

    schema do
      attribute :id, :string do
        description "Stable identifier of the work item targeted by this event."
        allow_nil? false
      end

      attribute :revision, :integer do
        description "Item generation that must match before a deadline can block the item."
        allow_nil? false
      end
    end
  end
end
