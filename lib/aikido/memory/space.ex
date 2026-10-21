defmodule Aikido.Memory.Space do
  @moduledoc """
  The unit of memory — a named container with typed data and revision tracking.

  A Space holds either a map (key-value) or list (ordered items) in its `data`
  field. The type is determined by the data itself — pattern matching and guards
  (`is_map/1`, `is_list/1`) handle dispatch.

  Each space tracks its own revision counter independently, enabling fine-grained
  concurrency control.

  ## Examples

      # Key-value space (world model)
      world = Space.new!(data: %{})
      world = %{world | data: Map.put(world.data, :temperature, 22)}

      # List space (task list)
      tasks = Space.new!(data: [])
      tasks = %{tasks | data: tasks.data ++ [%{id: "t1", text: "Check metric"}]}
  """

  use Ash.TypedStruct

  typed_struct do
    field :data, :term do
      description "Space contents — a map or list"
      allow_nil? false
      default %{}
    end

    field :rev, :integer do
      description "Per-space revision, increments on mutation"
      allow_nil? false
      default 0
    end

    field :metadata, :map do
      description "Space-level metadata"
      allow_nil? false
      default %{}
    end
  end

  @type t :: %__MODULE__{}
end
