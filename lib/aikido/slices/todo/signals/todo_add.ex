defmodule Aikido.Slices.Todo.Signals.TodoAdd do
  @moduledoc "Typed payload for `aikido.todo.add`."
  use Aikido.Signal

  signal do
    type "aikido.todo.add"

    schema do
      attribute :id, :string do
        description "Stable identifier of the work item targeted by this event."
        allow_nil? false
      end

      attribute :text, :string do
        description "Description of the work to add to the durable list."
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Application-owned workflow details attached to the new item."
        default %{}
      end

      attribute :blocking?, :boolean do
        description "Whether this unfinished item prevents todo-gated AI completion."
        default true
      end

      attribute :timeout_ms, :integer do
        description "Optional deadline duration scheduled when the item is added."
        constraints min: 1
      end
    end
  end
end
