defmodule Aikido.Slices.Thread.State do
  @moduledoc """
  An append-only log of interaction entries.

  Thread is the canonical record of "what happened" in a conversation
  or workflow. It is provider-agnostic and never modified destructively.

  LLM context is derived from Thread via projection functions, not
  stored directly in Thread.

  ## Example

      thread = Thread.new(metadata: %{user_id: "u1"})

      thread = Thread.append(thread, %{
        kind: :message,
        payload: %{role: "user", content: "Hello"}
      })

      Thread.entry_count(thread)  # => 1
      Thread.last(thread).kind    # => :message
  """

  alias Aikido.Slices.Thread.Entry
  alias Aikido.Slices.Thread.EntryNormalizer

  use Ash.TypedStruct

  typed_struct do
    field :id, :string,
      allow_nil?: false,
      description: "Unique thread identifier",
      constraints: [trim?: false, allow_empty?: true]

    field :rev, :integer,
      allow_nil?: false,
      default: 0,
      description: "Monotonic revision, increments on append"

    field :entries, {:array, :term},
      allow_nil?: false,
      default: [],
      description: "Ordered list of Entry structs"

    field :created_at, :integer, allow_nil?: false, description: "Creation timestamp (ms)"
    field :updated_at, :integer, allow_nil?: false, description: "Last update timestamp (ms)"
    field :metadata, :map, allow_nil?: false, default: %{}, description: "Arbitrary metadata"

    field :stats, :map,
      allow_nil?: false,
      default: %{entry_count: 0},
      description: "Cached aggregates"
  end

  @schema __MODULE__
  defoverridable new!: 1
  def new!(value), do: Aikido.Schema.cast!(__MODULE__, value)

  defoverridable cast_input: 2
  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints), do: Aikido.Schema.cast(__MODULE__, value)

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Thread."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema

  @doc "Create a new empty thread"
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    %__MODULE__{
      id: opts[:id] || generate_id(),
      rev: 0,
      entries: [],
      created_at: now,
      updated_at: now,
      metadata: opts[:metadata] || %{},
      stats: %{entry_count: 0}
    }
  end

  @doc "Append entries to thread (returns new thread)"
  @spec append(t(), Entry.t() | map() | [Entry.t() | map()]) :: t()
  def append(%__MODULE__{} = thread, entries) do
    entries = List.wrap(entries)
    now = System.system_time(:millisecond)
    base_seq = length(thread.entries)

    prepared_entries =
      EntryNormalizer.normalize_many(entries, base_seq, now)

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
  def clear(%__MODULE__{} = thread) do
    now = System.system_time(:millisecond)

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
  def entry_count(%__MODULE__{stats: %{entry_count: count}}), do: count

  @doc "Get last entry"
  @spec last(t()) :: Entry.t() | nil
  def last(%__MODULE__{entries: []}), do: nil
  def last(%__MODULE__{entries: entries}), do: List.last(entries)

  @doc "Get entry by seq"
  @spec get_entry(t(), non_neg_integer()) :: Entry.t() | nil
  def get_entry(%__MODULE__{entries: entries}, seq) do
    Enum.find(entries, &(&1.seq == seq))
  end

  @doc "Get all entries as list"
  @spec to_list(t()) :: [Entry.t()]
  def to_list(%__MODULE__{entries: entries}), do: entries

  @doc "Filter entries by kind"
  @spec filter_by_kind(t() | nil, atom() | [atom()]) :: [Entry.t()]
  def filter_by_kind(%__MODULE__{entries: entries}, kinds) when is_list(kinds) do
    Enum.filter(entries, &(&1.kind in kinds))
  end

  def filter_by_kind(nil, _kinds), do: []

  def filter_by_kind(%__MODULE__{} = thread, kind) when is_atom(kind) do
    filter_by_kind(thread, [kind])
  end

  @doc "Get entries in seq range (inclusive)"
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: [Entry.t()]
  def slice(%__MODULE__{entries: entries}, from_seq, to_seq) do
    Enum.filter(entries, fn e -> e.seq >= from_seq and e.seq <= to_seq end)
  end

  defp generate_id do
    "thread_" <> Aikido.Util.generate_id()
  end
end
