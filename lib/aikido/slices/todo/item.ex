defmodule Aikido.Slices.Todo.Item do
  @moduledoc "A typed work item with application-owned metadata and completion evidence."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string, allow_nil?: false
    field :text, :string, allow_nil?: false
    field :metadata, :map, default: %{}, allow_nil?: false
    field :blocking?, :boolean, default: true, allow_nil?: false

    field :status, :atom,
      default: :pending,
      allow_nil?: false,
      constraints: [one_of: [:pending, :active, :completed, :blocked]]

    field :result, :term
    field :reason, :term
    field :revision, :integer, default: 0, allow_nil?: false
    field :timeout_ms, :integer, constraints: [min: 1]
  end
end
