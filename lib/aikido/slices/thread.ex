defmodule Aikido.Slices.Thread do
  @moduledoc """
  Thread slice — owns the `:thread` key in agent state, mounted as a
  `%Aikido.Slices.Thread{}` append-only conversation log.

  ## State shape

  Declared by the embedded resource attributes. Mounted slices are initialized
  through their native create action before receiving signals. Reducers require
  the initialized resource struct and retain native Ash type validation.

  ## Routes

      route Aikido.Slices.Thread.Signals.Ensure, Aikido.Slices.Thread.Implementation
      route Aikido.Slices.Thread.Signals.Append, Aikido.Slices.Thread.Implementation
      route Aikido.Slices.Thread.Signals.Clear, Aikido.Slices.Thread.Implementation

  ## Persistence

  DurableServer snapshots retain the complete thread and its entries with the
  rest of the agent state.

  Mount with `slice :thread, Aikido.Slices.Thread` inside an agent resource.

  """

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "thread"
    description "Append-only conversation history thread for the agent."

    schema do
      attribute :id, :string do
        description "Thread identifier within the owning agent"
        default "thread"
        public? true
        allow_nil? false
        constraints trim?: false, allow_empty?: true
      end

      attribute :rev, :integer do
        description "Monotonic revision, increments on append"
        public? true
        allow_nil? false
        default 0
      end

      attribute :entries, {:array, Aikido.Slices.Thread.Entry} do
        description "Ordered list of Entry structs"
        public? true
        allow_nil? false
        default []
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

      attribute :stats, :map do
        description "Cached aggregates"
        public? true
        allow_nil? false
        default %{entry_count: 0}
      end
    end

    route Aikido.Slices.Thread.Signals.Ensure, Aikido.Slices.Thread.Implementation
    route Aikido.Slices.Thread.Signals.Append, Aikido.Slices.Thread.Implementation
    route Aikido.Slices.Thread.Signals.Clear, Aikido.Slices.Thread.Implementation
  end

  alias Aikido.Slices.Thread.Entry
  alias Aikido.Slices.Thread.EntryNormalizer
  @type t :: map()

  @doc "Create a new empty thread"
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    struct!(__MODULE__,
      id: opts[:id] || generate_id(),
      rev: 0,
      entries: [],
      created_at: now,
      updated_at: now,
      metadata: opts[:metadata] || %{},
      stats: %{entry_count: 0}
    )
  end

  @doc "Append entries to thread (returns new thread)"
  @spec append(t(), Entry.t() | map() | [Entry.t() | map()]) :: t()
  @spec append(t(), Entry.t() | map() | [Entry.t() | map()], keyword()) :: t()
  def append(%{__struct__: __MODULE__} = thread, entries, opts \\ []) do
    entries = List.wrap(entries)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)
    base_seq = length(thread.entries)
    prepared_entries = EntryNormalizer.normalize_many(entries, base_seq, now, opts)

    %{
      thread
      | entries: thread.entries ++ prepared_entries,
        rev: thread.rev + length(prepared_entries),
        updated_at: now,
        stats: %{thread.stats | entry_count: thread.stats.entry_count + length(prepared_entries)}
    }
  end

  @doc """
  Reset the thread to an empty state, preserving identity (`id`,
  `metadata`) and bumping the revision.
  """
  @spec clear(t()) :: t()
  @spec clear(t(), keyword()) :: t()
  def clear(%{__struct__: __MODULE__} = thread, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)

    %{
      thread
      | entries: [],
        rev: thread.rev + 1,
        updated_at: now,
        stats: %{thread.stats | entry_count: 0}
    }
  end

  @doc "Get entry count"
  @spec entry_count(t()) :: non_neg_integer()
  def entry_count(%{__struct__: __MODULE__, stats: %{entry_count: count}}) do
    count
  end

  @doc "Get last entry"
  @spec last(t()) :: Entry.t() | nil
  def last(%{__struct__: __MODULE__, entries: []}) do
    nil
  end

  def last(%{__struct__: __MODULE__, entries: entries}) do
    List.last(entries)
  end

  @doc "Get entry by seq"
  @spec get_entry(t(), non_neg_integer()) :: Entry.t() | nil
  def get_entry(%{__struct__: __MODULE__, entries: entries}, seq) do
    Enum.find(entries, &(&1.seq == seq))
  end

  @doc "Get all entries as list"
  @spec to_list(t()) :: [Entry.t()]
  def to_list(%{__struct__: __MODULE__, entries: entries}) do
    entries
  end

  @doc "Filter entries by kind"
  @spec filter_by_kind(t() | nil, atom() | [atom()]) :: [Entry.t()]
  def filter_by_kind(%{__struct__: __MODULE__, entries: entries}, kinds) when is_list(kinds) do
    Enum.filter(entries, &(&1.kind in kinds))
  end

  def filter_by_kind(nil, _kinds) do
    []
  end

  def filter_by_kind(%{__struct__: __MODULE__} = thread, kind) when is_atom(kind) do
    filter_by_kind(thread, [kind])
  end

  @doc "Get entries in seq range (inclusive)"
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: [Entry.t()]
  def slice(%{__struct__: __MODULE__, entries: entries}, from_seq, to_seq) do
    Enum.filter(entries, fn e -> e.seq >= from_seq and e.seq <= to_seq end)
  end

  defp generate_id do
    "thread_" <> Ash.UUIDv7.generate()
  end
end
