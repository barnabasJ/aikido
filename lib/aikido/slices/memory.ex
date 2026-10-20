defmodule Aikido.Slices.Memory do
  @moduledoc """
  Memory slice — owns the `:memory` key in agent state, mounted as a
  `%Aikido.Slices.Memory{}` value with named map / list spaces.

  ## State shape

  Declared by the embedded resource attributes. Mounted slices are initialized
  through their native create action before receiving signals. Reducers require
  the initialized resource struct and retain native Ash type validation.

  ## Routes

  Each `aikido.memory.*` signal type maps to a native action on
  `Aikido.Slices.Memory`:

      # ensure / put / update / delete
      route Aikido.Slices.Memory.Signals.Ensure, Aikido.Slices.Memory.Implementation
      route Aikido.Slices.Memory.Signals.PutSpace, Aikido.Slices.Memory.Implementation
      route Aikido.Slices.Memory.Signals.UpdateSpace, Aikido.Slices.Memory.Implementation
      route Aikido.Slices.Memory.Signals.EnsureSpace, Aikido.Slices.Memory.Implementation
      route Aikido.Slices.Memory.Signals.DeleteSpace, Aikido.Slices.Memory.Implementation

      # map space ops
      route Aikido.Slices.Memory.Signals.PutInSpace, Aikido.Slices.Memory.Implementation
      route Aikido.Slices.Memory.Signals.DeleteFromSpace, Aikido.Slices.Memory.Implementation

      # list space ops
      route Aikido.Slices.Memory.Signals.AppendToSpace, Aikido.Slices.Memory.Implementation

  Mount with `slice :memory, Aikido.Slices.Memory` inside an agent resource.

  ## Persistence

  DurableServer snapshots retain the complete memory state. For a custom
  serialized representation, implement
  your own slice that declares `@behaviour Aikido.Durable.Codec` and
  mount that custom resource instead.
  """

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "memory"
    description "Memory state for agent cognition — named map / list spaces."

    schema do
      attribute :id, :string do
        description "Memory identifier within the owning agent"
        default "memory"
        public? true
        allow_nil? false
        constraints trim?: false, allow_empty?: true
      end

      attribute :rev, :integer do
        description "Container-level monotonic revision"
        public? true
        allow_nil? false
        default 0
      end

      attribute :spaces, :map do
        description "Open map of named spaces"
        public? true
        allow_nil? false

        default %{
          world: %Aikido.Slices.Memory.Space{data: %{}},
          tasks: %Aikido.Slices.Memory.Space{data: []}
        }
      end

      attribute :created_at, :integer do
        description "Creation timestamp (ms)"
        default 0
        public? true
        allow_nil? false
      end

      attribute :updated_at, :integer do
        description "Last update timestamp (ms)"
        default 0
        public? true
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Arbitrary metadata"
        public? true
        allow_nil? false
        default %{}
      end
    end

    route Aikido.Slices.Memory.Signals.Ensure, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.PutSpace, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.UpdateSpace, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.EnsureSpace, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.DeleteSpace, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.PutInSpace, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.DeleteFromSpace, Aikido.Slices.Memory.Implementation
    route Aikido.Slices.Memory.Signals.AppendToSpace, Aikido.Slices.Memory.Implementation
  end

  alias Aikido.Slices.Memory.Space
  @type t :: map()

  @reserved_spaces [:tasks, :world]
  @doc "Returns the list of reserved (non-deletable) space names."
  @spec reserved_spaces() :: [atom()]
  def reserved_spaces do
    @reserved_spaces
  end

  @doc "Create a new memory with default world and tasks spaces."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    struct!(__MODULE__,
      id: opts[:id] || generate_id(),
      rev: 0,
      spaces: %{world: Space.new!(data: %{}), tasks: Space.new!(data: [])},
      created_at: now,
      updated_at: now,
      metadata: opts[:metadata] || %{}
    )
  end

  @doc "Get a space by name."
  @spec space(t() | nil, atom()) :: Space.t() | nil
  def space(nil, _name) do
    nil
  end

  def space(%{__struct__: __MODULE__, spaces: spaces}, name) when is_atom(name) do
    Map.get(spaces, name)
  end

  @doc "Check if a space exists."
  @spec has_space?(t() | nil, atom()) :: boolean()
  def has_space?(memory, name) do
    space(memory, name) != nil
  end

  @doc "Put a space wholesale. Bumps container rev and updated_at."
  @spec put_space(t(), atom(), Space.t(), keyword()) :: t()
  def put_space(%{__struct__: __MODULE__} = memory, name, %Space{} = new_space, opts \\ [])
      when is_atom(name) do
    now = opts[:now] || System.system_time(:millisecond)

    %{
      memory
      | spaces: Map.put(memory.spaces, name, new_space),
        rev: memory.rev + 1,
        updated_at: now
    }
  end

  @doc """
  Update a space using a function. Bumps both space and container revisions.

  Raises `ArgumentError` when the named space does not exist.
  """
  @spec update_space(t(), atom(), (Space.t() -> Space.t()), keyword()) :: t()
  def update_space(%{__struct__: __MODULE__} = memory, name, fun, opts \\ [])
      when is_atom(name) and is_function(fun, 1) do
    case Map.get(memory.spaces, name) do
      nil ->
        raise ArgumentError, "space #{inspect(name)} does not exist"

      current_space ->
        updated_space = fun.(current_space)
        updated_space = %{updated_space | rev: current_space.rev + 1}
        now = opts[:now] || System.system_time(:millisecond)

        %{
          memory
          | spaces: Map.put(memory.spaces, name, updated_space),
            rev: memory.rev + 1,
            updated_at: now
        }
    end
  end

  @doc """
  Ensure a space exists with default data. Does not overwrite existing.

  `default_data` selects the space kind: a map creates a kv space, a list
  creates a list space.
  """
  @spec ensure_space(t(), atom(), map() | list(), keyword()) :: t()
  def ensure_space(%{__struct__: __MODULE__} = memory, name, default_data, opts \\ [])
      when is_atom(name) do
    case space(memory, name) do
      nil ->
        new_space = %Space{data: default_data, rev: 0, metadata: %{}}
        put_space(memory, name, new_space, opts)

      _existing ->
        memory
    end
  end

  @doc "Delete a space. Raises on reserved spaces."
  @spec delete_space(t(), atom(), keyword()) :: t()
  def delete_space(%{__struct__: __MODULE__} = memory, name, opts \\ []) when is_atom(name) do
    if name in @reserved_spaces do
      raise ArgumentError, "cannot delete reserved space #{inspect(name)}"
    end

    now = opts[:now] || System.system_time(:millisecond)
    %{memory | spaces: Map.delete(memory.spaces, name), rev: memory.rev + 1, updated_at: now}
  end

  @doc "Get a key from a map space (returning `default` when absent)."
  @spec get_in_space(t() | nil, atom(), term(), term()) :: term()
  def get_in_space(memory, space_name, key, default \\ nil)

  def get_in_space(nil, _space_name, _key, default) do
    default
  end

  def get_in_space(%{__struct__: __MODULE__} = memory, space_name, key, default) do
    case space(memory, space_name) do
      %Space{data: data} when is_map(data) -> Map.get(data, key, default)
      nil -> default
      _ -> raise ArgumentError, "space #{inspect(space_name)} is not a map space"
    end
  end

  @doc "Put a key/value into a map space."
  @spec put_in_space(t(), atom(), term(), term(), keyword()) :: t()
  def put_in_space(%{__struct__: __MODULE__} = memory, space_name, key, value, opts \\ []) do
    validate_map_space!(memory, space_name)

    update_space(
      memory,
      space_name,
      fn space -> %{space | data: Map.put(space.data, key, value)} end,
      opts
    )
  end

  @doc "Delete a key from a map space."
  @spec delete_from_space(t(), atom(), term(), keyword()) :: t()
  def delete_from_space(%{__struct__: __MODULE__} = memory, space_name, key, opts \\ []) do
    validate_map_space!(memory, space_name)

    update_space(
      memory,
      space_name,
      fn space -> %{space | data: Map.delete(space.data, key)} end,
      opts
    )
  end

  @doc "Append an item to a list space."
  @spec append_to_space(t(), atom(), term(), keyword()) :: t()
  def append_to_space(%{__struct__: __MODULE__} = memory, space_name, item, opts \\ []) do
    validate_list_space!(memory, space_name)

    update_space(
      memory,
      space_name,
      fn space -> %{space | data: space.data ++ [item]} end,
      opts
    )
  end

  defp validate_map_space!(memory, space_name) do
    case space(memory, space_name) do
      %Space{data: data} when is_map(data) -> :ok
      nil -> raise ArgumentError, "space #{inspect(space_name)} does not exist"
      _ -> raise ArgumentError, "space #{inspect(space_name)} is not a map space"
    end
  end

  defp validate_list_space!(memory, space_name) do
    case space(memory, space_name) do
      %Space{data: data} when is_list(data) -> :ok
      nil -> raise ArgumentError, "space #{inspect(space_name)} does not exist"
      _ -> raise ArgumentError, "space #{inspect(space_name)} is not a list space"
    end
  end

  defp generate_id do
    "mem_" <> Ash.UUIDv7.generate()
  end
end
