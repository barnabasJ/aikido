defmodule Aikido.Slices.Todo.Item do
  @moduledoc "A typed work item with application-owned metadata and completion evidence."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Application-supplied stable identifier for this work item."
      allow_nil? false
    end

    field :text, :string do
      description "Description of the work whose completion the caller will report."
      allow_nil? false
    end

    field :metadata, :map do
      description "Application-owned workflow details retained with the work item."
      default %{}
      allow_nil? false
    end

    field :blocking?, :boolean do
      description "Whether this unfinished item prevents a todo-gated AI run from completing."
      default true
      allow_nil? false
    end

    field :status, Aikido.Slices.Todo.Types.Status do
      description "Current work state: pending, active, completed or blocked."
      default :pending
      allow_nil? false
    end

    field :result, :term do
      description "Explicit completion evidence supplied when the item is completed."
    end

    field :reason, :term do
      description "Reason the item is blocked, timed out or interrupted."
    end

    field :revision, :integer do
      description "Generation assigned on addition to reject stale deadline signals after ID reuse."
      default 0
      allow_nil? false
    end

    field :timeout_ms, :integer do
      description "Optional deadline duration scheduled when the item is added."
      constraints min: 1
    end
  end
end
