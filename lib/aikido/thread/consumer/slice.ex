defmodule Aikido.Thread.Consumer.Slice do
  @moduledoc """
  Notification-driven journal demand with one global SQL-work window.

  Mount once on an ordinary storage agent. Implement a routed action for
  `Aikido.Thread.Consumer.Signals.Work`, perform the application's scoped SQL
  write through an AsyncTask, then return `Committed` only after commit or
  `Failed` with a public error. This slice owns replay, roster discovery and Ack;
  application code owns admission, masking and database work.

  Credits retain only addresses and range correlation. Entry payloads remain in
  source journals and transient Work signals, not per-source pending buffers.
  """
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

  slice do
    name "journal_consumer"
    singleton?(true)

    schema do
      attribute :paused?, :boolean do
        description "A completed or blocked explicit drain pauses fresh demand."
        default false
        allow_nil? false
      end

      attribute :drain_request_id, :string do
        description "Drain signal currently waiting for fresh confirmed source heads and sink commits."
      end

      attribute :drained_request_id, :string do
        description "Last successfully completed drain, checked from native state when awaiting completion."
      end

      attribute :roots, {:array, Aikido.Agent.Reference} do
        description "Explicit root sources to follow on activation, without granting read permission."
        default []
        allow_nil? false
      end

      attribute :follow_parent?, :boolean do
        description "Bootstrap the owning Team's roster and Thread mounts from the existing parent binding."
        default true
        allow_nil? false
      end

      attribute :sources, {:array, Aikido.Thread.Consumer.Types.Source} do
        description "Durable source addresses, SQL cursors and coalesced availability; no entry payloads."
        default []
        allow_nil? false
        constraints max_length: 131_072
      end

      attribute :credits, {:array, Aikido.Thread.Consumer.Types.Credit} do
        description "Globally bounded demand or SQL-work slots across every source."
        default []
        allow_nil? false
        constraints max_length: 32
      end

      attribute :window, :integer do
        description "Maximum outstanding demand and SQL-work batches across the entire writer."
        default 1
        allow_nil? false
        constraints min: 1, max: 32
      end

      attribute :batch_size, :integer do
        description "Maximum entries requested in one source batch; this is an entry-count bound, not a byte-size limit."
        default 100
        allow_nil? false
        constraints min: 1, max: 1000
      end

      attribute :request_timeout_ms, :integer do
        description "Retry a source request that produced no response, without polling source state."
        default 5_000
        allow_nil? false
        constraints min: 1
      end
    end

    route Aikido.Thread.Consumer.Signals.Drain, Aikido.Thread.Consumer.Actions.Drain,
      name: :drain_journals

    route Aikido.Thread.Consumer.Signals.Resume, Aikido.Thread.Consumer.Actions.Resume,
      name: :continue_journals

    route [Aikido.Thread.Consumer.Signals.Drained, Aikido.Thread.Consumer.Signals.DrainBlocked],
          Aikido.Thread.Consumer.Actions.DrainResult, name: :journal_drain_result, public?: false

    route Aikido.Thread.Consumer.Signals.Watch, Aikido.Thread.Consumer.Actions.Watch,
      name: :watch_journal

    route Aikido.Thread.Consumer.Signals.Retry, Aikido.Thread.Consumer.Actions.Retry,
      name: :retry_journal

    route Aikido.Thread.Signals.Batch, Aikido.Thread.Consumer.Actions.Batch,
      name: :receive_journal_batch,
      public?: false

    route Aikido.Thread.Signals.Available, Aikido.Thread.Consumer.Actions.Available,
      name: :journal_available,
      public?: false

    route Aikido.Thread.Signals.Gap, Aikido.Thread.Consumer.Actions.Gap,
      name: :journal_gap,
      public?: false

    route Aikido.Thread.Signals.Rejected, Aikido.Thread.Consumer.Actions.Rejected,
      name: :journal_rejected,
      public?: false

    route Aikido.Thread.Signals.Unavailable, Aikido.Thread.Consumer.Actions.Unavailable,
      name: :journal_unavailable,
      public?: false

    route Aikido.Thread.Consumer.Signals.Committed, Aikido.Thread.Consumer.Actions.Committed

    route Aikido.Thread.Consumer.Signals.Failed, Aikido.Thread.Consumer.Actions.Failed

    route Aikido.Thread.Consumer.Signals.RequestTimeout,
          Aikido.Thread.Consumer.Actions.RequestTimeout, public?: false

    route Aikido.AgentServer.Signals.LifecycleReady, Aikido.Thread.Consumer.Actions.Ready,
      name: :resume_journals,
      public?: false
  end
end
