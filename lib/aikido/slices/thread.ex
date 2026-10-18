defmodule Aikido.Slices.Thread do
  @moduledoc """
  Thread slice — owns the `:thread` key in agent state, mounted as a
  `%Aikido.Slices.Thread.State{}` append-only conversation log.

  ## State shape

  Bound to `Aikido.Slices.Thread.State.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `aikido.thread.*` signal materializes a fresh
  `%Aikido.Slices.Thread.State{}` via the relevant action.

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

  alias Aikido.Slices.Thread.Actions
  alias Aikido.Slices.Thread.State

  use Aikido.Slice

  slice do
    name "thread"
    description "Append-only conversation history thread for the agent."

    schema do
      attribute :id, :string,
        allow_nil?: false,
        description: "Unique thread identifier",
        constraints: [trim?: false, allow_empty?: true]

      attribute :rev, :integer,
        allow_nil?: false,
        default: 0,
        description: "Monotonic revision, increments on append"

      attribute :entries, {:array, :term},
        allow_nil?: false,
        default: [],
        description: "Ordered list of Entry structs"

      attribute :created_at, :integer, allow_nil?: false, description: "Creation timestamp (ms)"

      attribute :updated_at, :integer,
        allow_nil?: false,
        description: "Last update timestamp (ms)"

      attribute :metadata, :map,
        allow_nil?: false,
        default: %{},
        description: "Arbitrary metadata"

      attribute :stats, :map,
        allow_nil?: false,
        default: %{entry_count: 0},
        description: "Cached aggregates"
    end

    state_transform {Aikido.Schema, :to_struct, [State]}
  end

  signal_routes do
    route "aikido.thread.ensure", Actions.Ensure
    route "aikido.thread.append", Actions.Append
    route "aikido.thread.clear", Actions.Clear
  end

  capabilities do
    capability :thread
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
  def externalize(%State{id: id, rev: rev}), do: %{id: id, rev: rev}
  def externalize(nil), do: nil
  def externalize(other), do: other

  @impl Aikido.Persist.Transform
  def reinstate(value), do: value
end
