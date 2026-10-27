defmodule Aikido.Thread.Slice do
  @moduledoc """
  Thread slice — owns the `:thread` key in agent state, mounted as a
  `%Aikido.Thread.Slice{}` append-only conversation log.

  ## State shape

  Declared by the embedded resource attributes. Mounted slices are initialized
  through their native create action before receiving signals. Reducers require
  the initialized resource struct and retain native Ash type validation.

  ## Routes

      route Aikido.Thread.Signals.Append, Aikido.Thread.Actions.Append
      route Aikido.Thread.Signals.Clear, Aikido.Thread.Actions.Clear

  ## Persistence

  DurableServer snapshots retain the complete thread and its entries with the
  rest of the agent state.

  Mount with `slice :thread, Aikido.Thread.Slice` inside an agent resource.

  """

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension]

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
        description "Revision incremented for each appended entry and every clear operation"
        public? true
        allow_nil? false
        default 0
      end

      attribute :entries, {:array, Aikido.Thread.Types.Entry} do
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

    route Aikido.Thread.Signals.Append, Aikido.Thread.Actions.Append
    route Aikido.Thread.Signals.Clear, Aikido.Thread.Actions.Clear
  end
end
