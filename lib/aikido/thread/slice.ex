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
      attribute :replay?, :boolean do
        description "Opt into immutable replay receipts and cursor-based Follow/Prune; ordinary threads avoid receipt hashing and retention."
        default false
        allow_nil? false
      end

      attribute :generation, :string do
        description "Durable generation identity allocated by native initialization and changed by Clear."
        default &Ash.UUIDv7.generate/0
        allow_nil? false
        public? true
      end

      attribute :last_clear_id, :string do
        description "Most recently accepted Clear signal ID, retained across intervening appends to ignore its retry."
      end

      attribute :next_sequence, :integer do
        description "Next sequence, preserved when older entries are pruned."
        default 0
        allow_nil? false
        constraints min: 0
      end

      attribute :first_sequence, :integer do
        description "Retention floor; cursors below this floor receive an explicit gap."
        default 0
        allow_nil? false
        constraints min: 0
      end

      attribute :followers, {:array, Aikido.Thread.Types.Follower} do
        description "Authorized durable consumer cursors with one bounded outstanding range each."
        default []
        allow_nil? false
        constraints max_length: 128
      end

      attribute :entry_receipts, {:array, Aikido.Thread.Types.EntryReceipt} do
        description "Immutable entry identity receipts retained through pruning; grows until Clear or identity deletion."
        default []
        allow_nil? false
      end

      attribute :retry_ms, :integer do
        description "Native scheduled redelivery interval while a batch remains unacknowledged."
        default 5_000
        allow_nil? false
        constraints min: 1
      end

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
    route Aikido.Thread.Signals.Follow, Aikido.Thread.Actions.Follow
    route Aikido.Thread.Signals.Ack, Aikido.Thread.Actions.Ack
    route Aikido.Thread.Signals.Unfollow, Aikido.Thread.Actions.Unfollow
    route Aikido.Thread.Signals.Prune, Aikido.Thread.Actions.Prune
    route Aikido.Thread.Signals.Retry, Aikido.Thread.Actions.Retry, public?: false

    route Aikido.AgentServer.Signals.LifecycleReady, Aikido.Thread.Actions.ResumeFollowers,
      public?: false
  end
end
