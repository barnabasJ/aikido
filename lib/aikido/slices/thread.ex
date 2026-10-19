defmodule Aikido.Slices.Thread do
  @moduledoc """
  Thread slice — owns the `:thread` key in agent state, mounted as a
  `%Aikido.Slices.Thread{}` append-only conversation log.

  ## State shape

  Bound to `Aikido.Slices.Thread.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `aikido.thread.*` signal materializes a fresh
  `%Aikido.Slices.Thread{}` via the relevant action.

  ## Routes

      route "aikido.thread.ensure", Actions.Ensure
      route "aikido.thread.append", Actions.Append
      route "aikido.thread.clear",  Actions.Clear

  ## Persistence

  This slice implements `Aikido.Persist.Transform` to externalize the thread
  to its small pointer (`%{id, rev}`) on checkpoint. `reinstate/1` is a
  passthrough — actual rehydration happens via the existing
  `Aikido.Persist.thaw/3` path.

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Aikido.Agent, default_slices: %{thread: false}

      agent do
        name "minimal"
      end
  """

  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "thread"
    description "Append-only conversation history thread for the agent."

    schema do
      attribute :id, :string,
        public?: true,
        allow_nil?: false,
        description: "Unique thread identifier",
        constraints: [trim?: false, allow_empty?: true]

      attribute :rev, :integer,
        public?: true,
        allow_nil?: false,
        default: 0,
        description: "Monotonic revision, increments on append"

      attribute :entries, {:array, :term},
        public?: true,
        allow_nil?: false,
        default: [],
        description: "Ordered list of Entry structs"

      attribute :created_at, :integer,
        public?: true,
        allow_nil?: false,
        description: "Creation timestamp (ms)"

      attribute :updated_at, :integer,
        public?: true,
        allow_nil?: false,
        description: "Last update timestamp (ms)"

      attribute :metadata, :map,
        public?: true,
        allow_nil?: false,
        default: %{},
        description: "Arbitrary metadata"

      attribute :stats, :map,
        public?: true,
        allow_nil?: false,
        default: %{entry_count: 0},
        description: "Cached aggregates"
    end

    route "aikido.thread.ensure", :ensure
    route "aikido.thread.append", :append
    route "aikido.thread.clear", :clear
  end

  @thread_section %Spark.Dsl.Section{
    name: :thread,
    describe: "Configuration block contributed by Aikido.Slices.Thread.",
    schema: []
  }
  use Spark.Dsl.Extension,
    sections: [@thread_section],
    transformers: [Aikido.Slices.Thread.Transformers.RegisterContribution]

  @behaviour Aikido.Persist.Transform
  @impl Aikido.Persist.Transform
  def externalize(%{__struct__: __MODULE__, id: id, rev: rev}) do
    %{id: id, rev: rev}
  end

  def externalize(nil) do
    nil
  end

  def externalize(other) do
    other
  end

  @impl Aikido.Persist.Transform
  def reinstate(value) do
    value
  end

  actions do
    action :append, Aikido.ActionResult do
      argument :state, :term

      argument :entry, :union,
        description: "Entry map (or list of entry maps) to append.",
        allow_nil?: false,
        constraints: [
          types: [entry: [type: :map], entries: [type: {:array, :map}]]
        ]

      description "Append one or more entries to the thread."
      run {Aikido.Slices.Thread.Implementation, action: :append}
    end

    action :clear, Aikido.ActionResult do
      argument :state, :term
      description "Reset the thread to an empty state."
      run {Aikido.Slices.Thread.Implementation, action: :clear}
    end

    action :ensure, Aikido.ActionResult do
      argument :state, :term

      argument :metadata, :map,
        description: "Optional metadata for newly created thread.",
        default: %{}

      argument :id, :string, description: "Optional explicit thread id."
      description "Initialize thread state if missing."
      run {Aikido.Slices.Thread.Implementation, action: :ensure}
    end
  end

  alias Aikido.Slices.Thread.Entry
  alias Aikido.Slices.Thread.EntryNormalizer
  @type t :: map()
  @schema __MODULE__
  def new!(value) do
    value |> then(&Ash.Type.cast_input(__MODULE__, &1)) |> Ash.Helpers.unwrap_or_raise!()
  end

  @doc "Returns the Ash type for Thread."
  @spec schema() :: Ash.Type.t()
  def schema do
    @schema
  end

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
    "thread_" <> Aikido.Util.generate_id()
  end
end
