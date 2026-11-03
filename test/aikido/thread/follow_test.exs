defmodule Aikido.ThreadFollowTest.Role do
  use Ash.Type.Enum, values: [:publisher, :writer, :outsider]
end

defmodule Aikido.ThreadFollowTest.Access do
  @moduledoc "External application access records used by native source policies."
  use Ash.Resource, domain: Aikido.ThreadFollowTest.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :id, :string do
      description "Application actor identity."
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :role, Aikido.ThreadFollowTest.Role do
      description "Explicit application permission role."
      allow_nil? false
      public? true
    end

    attribute :reader?, :boolean do
      description "Current permission to read source journals."
      default false
      allow_nil? false
      public? true
    end

    attribute :active?, :boolean do
      description "Current business actor activity, checked natively rather than resolved into agent scope."
      default true
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:id, :role, :reader?, :active?],
      update: [:reader?, :active?]
    ]
  end
end

defmodule Aikido.ThreadFollowTest.SourcePolicy do
  use Ash.Policy.SimpleCheck

  @requests [
    "aikido.thread.follow",
    "aikido.thread.ack",
    "aikido.thread.unfollow",
    "aikido.ash.team.follow_roster",
    "aikido.ash.team.ack_roster",
    "aikido.ash.team.unfollow_roster"
  ]

  @impl true
  def describe(_options),
    do: "current application grant allows publishing or this journal read operation"

  @impl true
  def match?(%{id: id}, %{subject: subject}, _options) do
    case Ash.get(Aikido.ThreadFollowTest.Access, id, authorize?: false) do
      {:ok, %{active?: true, role: :publisher}} ->
        true

      {:ok, %{active?: true, role: :writer, reader?: true}} ->
        subject.action.name in [
          :follow,
          :ack,
          :unfollow,
          :follow_roster,
          :ack_roster,
          :unfollow_roster
        ] ||
          get_in(subject.context, [:aikido, :signal, Access.key(:type)]) in @requests

      _ ->
        false
    end
  end

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.ThreadFollowTest.WriterPolicy do
  use Ash.Policy.SimpleCheck
  @impl true
  def describe(_options), do: "the current application writer principal is active"
  @impl true
  def match?(%{id: id}, _context, _options) do
    case Ash.get(Aikido.ThreadFollowTest.Access, id, authorize?: false) do
      {:ok, %{active?: true, role: role}} when role in [:writer, :publisher] -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.ThreadFollowTest.Authority do
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    id = get_in(attributes, [:state, :actor_id])
    options = if id, do: Keyword.put(options, :actor, %{id: id, allowed: true}), else: options
    AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.ThreadFollowTest.Source do
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "journal_source"
    persistence :permanent
    slice :thread, Aikido.Thread.Slice

    schema do
      attribute :actor_id, :string do
        description "Identity authenticated by the durable scope adapter."
        allow_nil? false
      end
    end
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.HoldWork do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    Aikido.Types.ActionResult.new(
      changes: %{
        last_work: Map.delete(input.arguments, :state),
        works_received: input.arguments.state.works_received + 1,
        last_actor: input.context.aikido.actor.id
      }
    )
  end
end

defmodule Aikido.ThreadFollowTest.Writer do
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "journal_writer"
    persistence :permanent
    slice :journal_consumer, Aikido.Thread.Consumer.Slice

    schema do
      attribute :actor_id, :string do
        description "Authenticated writer principal."
        allow_nil? false
      end

      attribute :last_work, :map do
        description "One held external work batch for explicit commit-boundary tests, not a source backlog."
      end

      attribute :works_received, :integer do
        description "Number of work batches offered to this test application."
        default 0
        allow_nil? false
      end

      attribute :last_actor, :string do
        description "Actual native receiving principal."
      end
    end

    route Aikido.Thread.Consumer.Signals.Work, Aikido.ThreadFollowTest.HoldWork, public?: false
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.WriterPolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.Team do
  use Ash.Resource,
    domain: Aikido.ThreadFollowTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "journal_team"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Authenticated team publisher."
        allow_nil? false
      end
    end
  end

  team do
    roster_history?(true)
    inherit [:actor_id]
    worker :source, Aikido.ThreadFollowTest.Source
    worker :writer, Aikido.ThreadFollowTest.Writer
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.OptionalRosterTeam do
  @moduledoc "An ordinary team initially configured without retained roster history."
  use Ash.Resource,
    domain: Aikido.ThreadFollowTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "optional_roster_team"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Authenticated owner of the retained team."
        allow_nil? false
      end
    end
  end

  team do
    inherit [:actor_id]
    worker :source, Aikido.ThreadFollowTest.Source
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.HoldRequest do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end

defmodule Aikido.ThreadFollowTest.ReplyAvailability do
  use Aikido.Signal

  signal do
    type "test.journal.reply_availability"

    schema do
      attribute :consumer, Aikido.Agent.Reference do
        description "Actual consumer expecting this delayed source response."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Follow request whose response this source is now releasing."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.ThreadFollowTest.SendAvailability do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    context = input.context.aikido

    source =
      Aikido.Agent.Reference.new!(
        id: context.agent_id,
        resource: context.agent_module,
        aikido: context.aikido,
        partition: context.partition
      )

    data = %{
      source: source,
      consumer: input.arguments.consumer,
      request_id: input.arguments.request_id,
      path: :thread,
      channel: :thread,
      batch: nil,
      cursor: Aikido.Thread.Types.Cursor.new!(generation: "pending", sequence: -1),
      pending?: false
    }

    reply = %Aikido.Signal{type: "aikido.thread.available", data: data}

    Aikido.Types.ActionResult.new(
      directives: [
        Aikido.Thread.Directives.Deliver.new!(
          target: input.arguments.consumer,
          signal: reply,
          kind: :batch
        )
      ]
    )
  end
end

defmodule Aikido.ThreadFollowTest.PendingSource do
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain

  agent do
    name "pending_journal_source"

    schema do
      attribute :actor_id, :string do
        description "Identity authenticated at source activation."
        allow_nil? false
      end
    end

    route Aikido.Thread.Signals.Follow, Aikido.ThreadFollowTest.HoldRequest
    route Aikido.ThreadFollowTest.ReplyAvailability, Aikido.ThreadFollowTest.SendAvailability
  end
end

defmodule Aikido.ThreadFollowTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.ThreadFollowTest.Access
  end

  agents do
    agent :source, Aikido.ThreadFollowTest.Source
    agent :pending_source, Aikido.ThreadFollowTest.PendingSource
    agent :writer, Aikido.ThreadFollowTest.Writer
    agent :journal_team, Aikido.ThreadFollowTest.Team
    agent :optional_roster_team, Aikido.ThreadFollowTest.OptionalRosterTeam
  end
end

defmodule Aikido.ThreadFollowTest do
  use AikidoTest.Case, async: false
  alias Aikido.ThreadFollowTest.Domain
  alias Aikido.Agent.Reference

  setup do
    options = Keyword.put(durable_options(), :scope_adapter, Aikido.ThreadFollowTest.Authority)
    start_supervised!({Aikido, name: Aikido.Default, durable: options})
    publisher = actor(:publisher)
    writer = actor(:writer)
    {:ok, publisher: publisher, writer_actor: writer}
  end

  test "late startup replays bounded original entries and waits for an explicit external commit",
       ctx do
    source = start_source(ctx.publisher)

    entries =
      Enum.map(0..4, &%{id: "entry-#{&1}", at: 123 + &1, payload: %{text: "original #{&1}"}})

    receipt = Domain.source_append!(source, %{entry: entries}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    first = await_work(writer, ["entry-0", "entry-1"])
    assert Enum.map(first.entries, & &1.at) == [123, 124]
    assert Enum.all?(first.entries, &(&1.refs.signal_id == receipt.signal_id))
    assert snapshot(writer).last_actor == ctx.writer_actor.id
    state = snapshot(source).thread
    assert [%{cursor: %{sequence: -1}, in_flight: batch}] = state.followers
    assert batch == first.batch
    assert length(snapshot(writer).journal_consumer.credits) == 1
    refute Map.has_key?(hd(snapshot(writer).journal_consumer.credits), :entries)

    commit(writer, first, ctx.writer_actor)
    second = await_work(writer, ["entry-2", "entry-3"])
    assert second.batch.first_sequence == 2
    commit(writer, second, ctx.writer_actor)
    third = await_work(writer, ["entry-4"])
    commit(writer, third, ctx.writer_actor)

    await_state_value(writer.pid, fn runtime ->
      consumer = runtime.agent.state.journal_consumer
      if consumer.credits == [] && hd(consumer.sources).cursor.sequence == 4, do: true
    end)
  end

  test "a slow writer reserves one global window rather than one payload buffer per source",
       ctx do
    source1 = start_source(ctx.publisher)
    publisher2 = actor(:publisher)
    source2 = start_source(publisher2)

    Domain.source_append!(source1, %{entry: %{id: "one", payload: %{text: "one"}}},
      scope: scope(ctx.publisher)
    )

    Domain.source_append!(source2, %{entry: %{id: "two", payload: %{text: "two"}}},
      scope: scope(publisher2)
    )

    writer = start_writer(ctx.writer_actor, [reference(source1), reference(source2)])
    first = await_work(writer, ["one"])
    assert snapshot(source2).thread.followers == []
    assert length(snapshot(writer).journal_consumer.credits) == 1
    commit(writer, first, ctx.writer_actor)
    await_work(writer, ["two"])
    assert length(snapshot(writer).journal_consumer.credits) == 1
  end

  test "an offered prefix survives abrupt source death before its periodic snapshot", ctx do
    source =
      Domain.source_start!(
        %{
          id: ctx.publisher.id,
          actor_id: ctx.publisher.id,
          thread: %{retry_ms: 60_000, replay?: true},
          sync: %{mode: :periodic, interval_ms: 3_600_000}
        },
        scope: scope(ctx.publisher)
      )

    assert {:ok, %{mode: :periodic, interval_ms: 3_600_000}} =
             Aikido.AgentServer.state(source.pid, &{:ok, &1.sync})

    Domain.source_append!(source, %{entry: %{id: "durable-before-delivery"}},
      scope: scope(ctx.publisher)
    )

    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["durable-before-delivery"])
    commit(writer, work, ctx.writer_actor)

    replacement = AikidoTest.LifecycleWait.crash_and_await_replacement(source.pid)
    restored = %{source | pid: replacement}
    assert [%{id: "durable-before-delivery", seq: 0}] = snapshot(restored).thread.entries
    assert snapshot(restored).thread.generation == work.batch.generation

    Domain.source_append!(restored, %{entry: %{id: "after-crash"}}, scope: scope(ctx.publisher))
    next = await_work(writer, ["after-crash"])
    assert next.batch.first_sequence == 1
    assert next.batch.generation == work.batch.generation
  end

  test "a direct reconstructed private reply cannot impersonate a journal source", ctx do
    source =
      Domain.pending_source_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    writer = start_writer(ctx.writer_actor, [])

    Domain.writer_watch_journal!(writer, %{source: reference(source)},
      scope: scope(ctx.writer_actor)
    )

    [credit] = snapshot(writer).journal_consumer.credits

    forged =
      Aikido.Thread.Signals.Batch.new!(
        %{
          source: reference(source),
          consumer: reference(writer),
          path: :thread,
          channel: :thread,
          request_id: credit.id,
          batch: %{id: credit.id, generation: "invented", first_sequence: 0, last_sequence: 0},
          entries: [%{id: "forged", seq: 0, at: 1, payload: %{text: "forged"}}]
        },
        scope:
          Map.put(scope(ctx.writer_actor), :__delivery__, %{
            protocol: Aikido.Thread.Delivery,
            kind: :batch
          })
      )

    assert {:error, %Ash.Error.Forbidden{} = error} =
             Aikido.AgentServer.call(writer.pid, forged, &{:ok, &1.agent})

    assert Exception.message(error) =~ "runtime-correlated source delivery"
    assert snapshot(writer).works_received == 0
    assert [%{phase: :requesting}] = snapshot(writer).journal_consumer.credits
  end

  test "direct Work cannot start application work without runtime delivery", ctx do
    source = start_source(ctx.publisher)
    writer = start_writer(ctx.writer_actor, [])

    forged =
      Aikido.Thread.Consumer.Signals.Work.new!(
        %{
          source: reference(source),
          batch: %{id: "fabricated", generation: "invented", first_sequence: 0, last_sequence: 0},
          entries: [%{id: "forged", seq: 0, at: 1, payload: %{text: "forged"}}]
        },
        scope: scope(ctx.writer_actor)
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(writer.pid, forged, &{:ok, &1.agent})

    assert snapshot(writer).works_received == 0
    assert snapshot(writer).journal_consumer.credits == []
  end

  test "direct Work cannot impersonate even an existing writing credit", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "real-work"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["real-work"])

    forged =
      Aikido.Thread.Consumer.Signals.Work.new!(work,
        scope:
          Map.put(scope(ctx.writer_actor), :__delivery__, %{
            protocol: Aikido.Thread.Delivery,
            kind: :work
          })
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(writer.pid, forged, &{:ok, &1.agent})

    assert snapshot(writer).works_received == 1
    assert [%{phase: :writing}] = snapshot(writer).journal_consumer.credits
  end

  test "manual settlement commands authorize even when no writing credit matches", ctx do
    source = start_source(ctx.publisher)
    writer = start_writer(ctx.writer_actor, [])
    outsider = actor(:outsider)

    data = %{
      source: reference(source),
      batch: %{id: "no-credit", generation: "invented", first_sequence: 0, last_sequence: 0}
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.writer_committed(writer, data, scope: scope(outsider))

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.writer_failed(writer, Map.put(data, :message, "sink failure"),
               scope: scope(outsider)
             )

    for signal <- [
          Aikido.Thread.Consumer.Signals.Committed.new!(data, scope: scope(outsider)),
          Aikido.Thread.Consumer.Signals.Failed.new!(Map.put(data, :message, "sink failure"),
            scope: scope(outsider)
          )
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Aikido.AgentServer.call(writer.pid, signal, &{:ok, &1.agent})
    end

    Domain.writer_committed!(writer, data, scope: scope(ctx.writer_actor))

    Domain.writer_failed!(writer, Map.put(data, :message, "sink failure"),
      scope: scope(ctx.writer_actor)
    )

    assert snapshot(writer).journal_consumer.credits == []
    assert snapshot(writer).works_received == 0
  end

  test "a pre-drain availability cannot satisfy its replacement head request", ctx do
    source =
      Domain.pending_source_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    writer = start_writer(ctx.writer_actor, [])

    Domain.writer_watch_journal!(writer, %{source: reference(source)},
      scope: scope(ctx.writer_actor)
    )

    [old] = snapshot(writer).journal_consumer.credits
    drain = Domain.writer_drain_journals!(writer, %{}, scope: scope(ctx.writer_actor))
    [fresh] = snapshot(writer).journal_consumer.credits
    refute fresh.id == old.id

    Domain.pending_source_reply_availability!(
      source,
      %{consumer: reference(writer), request_id: old.id},
      scope: scope(ctx.publisher)
    )

    await_state_value(writer.pid, fn runtime ->
      if hd(runtime.agent.state.journal_consumer.sources).status == :watching, do: true
    end)

    consumer = snapshot(writer).journal_consumer
    assert consumer.drain_request_id == drain.signal_id
    assert consumer.credits == [fresh]
    refute consumer.drained_request_id == drain.signal_id

    Domain.pending_source_reply_availability!(
      source,
      %{consumer: reference(writer), request_id: fresh.id},
      scope: scope(ctx.publisher)
    )

    await_state_value(writer.pid, fn runtime ->
      if runtime.agent.state.journal_consumer.drained_request_id == drain.signal_id, do: true
    end)
  end

  test "native configuration enables retained history without replacing its entries", ctx do
    original_metadata = %{user: %{label: "preserved"}, routing: %{display: "existing"}}

    source =
      Domain.source_start!(
        %{
          id: ctx.publisher.id,
          actor_id: ctx.publisher.id,
          thread: %{metadata: original_metadata}
        },
        scope: scope(ctx.publisher)
      )

    Domain.source_append!(source, %{entry: [%{id: "old-a", at: 1}, %{id: "old-b", at: 2}]},
      scope: scope(ctx.publisher)
    )

    original = snapshot(source).thread
    refute original.replay?
    assert original.entry_receipts == []

    patch = %{routing: %{organization: "example-org", thread: "example-thread"}}
    Domain.source_configure_replay!(source, %{metadata: patch}, scope: scope(ctx.publisher))
    configured = snapshot(source).thread
    assert configured.replay?
    assert configured.entries == original.entries
    assert configured.generation == original.generation
    assert configured.next_sequence == 2
    assert length(configured.entry_receipts) == 2
    assert configured.metadata.user == original_metadata.user
    assert configured.metadata.routing.display == "existing"
    assert configured.metadata.routing.thread == "example-thread"

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.source_configure_replay(
               source,
               %{metadata: %{routing: %{thread: "forbidden"}}},
               scope: scope(ctx.writer_actor)
             )

    assert snapshot(source).thread == configured
    Domain.source_configure_replay!(source, %{metadata: patch}, scope: scope(ctx.publisher))
    assert snapshot(source).thread == configured

    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["old-a", "old-b"])
    assert work.entries == original.entries
    assert work.metadata == configured.metadata
  end

  test "invalid legacy identity cannot be silently rewritten by replay configuration", ctx do
    source =
      Domain.source_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    Domain.source_append!(source, %{entry: [%{id: "duplicate"}, %{id: "duplicate"}]},
      scope: scope(ctx.publisher)
    )

    original = snapshot(source).thread

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.source_configure_replay(source, %{}, scope: scope(ctx.publisher))

    assert Exception.message(error) =~ "unique entry IDs"
    assert snapshot(source).thread == original
  end

  test "confirmed source metadata accompanies replay as data", ctx do
    metadata = %{
      routing: %{organization: "example-org", thread: "example-thread"},
      user: %{label: "retained"}
    }

    source =
      Domain.source_start!(
        %{
          id: ctx.publisher.id,
          actor_id: ctx.publisher.id,
          thread: %{replay?: true, metadata: metadata}
        },
        scope: scope(ctx.publisher)
      )

    Domain.source_append!(source, %{entry: %{id: "routed"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    assert await_work(writer, ["routed"]).metadata == metadata
    restored = AikidoTest.LifecycleWait.crash_and_await_replacement(source.pid)

    assert {:ok, ^metadata} =
             Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.thread.metadata})
  end

  test "drain checks a fresh source head, commits its suffix and pauses demand", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "first"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    commit(writer, await_work(writer, ["first"]), ctx.writer_actor)

    assert {:ok, _} =
             Aikido.AgentServer.call_until(
               writer.pid,
               fn ->
                 Domain.writer_drain_journals(writer, %{}, scope: scope(ctx.writer_actor))
               end,
               "aikido.thread.consumer.drained",
               fn runtime ->
                 consumer = runtime.agent.state.journal_consumer

                 if consumer.paused? && consumer.drained_request_id,
                   do: {:ok, consumer},
                   else: :skip
               end
             )

    Domain.source_append!(source, %{entry: %{id: "while-paused"}}, scope: scope(ctx.publisher))

    await_state_value(writer.pid, fn runtime ->
      if hd(runtime.agent.state.journal_consumer.sources).head.sequence == 1, do: true
    end)

    assert snapshot(writer).works_received == 1

    receipt = Domain.writer_drain_journals!(writer, %{}, scope: scope(ctx.writer_actor))
    work = await_work(writer, ["while-paused"])
    refute snapshot(writer).journal_consumer.drained_request_id == receipt.signal_id
    assert [%{phase: :writing}] = snapshot(writer).journal_consumer.credits
    commit(writer, work, ctx.writer_actor)

    await_state_value(writer.pid, fn runtime ->
      consumer = runtime.agent.state.journal_consumer

      if consumer.paused? && consumer.drained_request_id == receipt.signal_id &&
           consumer.credits == [],
         do: true
    end)

    Domain.source_append!(source, %{entry: %{id: "after-drain"}}, scope: scope(ctx.publisher))
    Domain.writer_continue_journals!(writer, %{}, scope: scope(ctx.writer_actor))
    assert await_work(writer, ["after-drain"]).batch.first_sequence == 2
  end

  test "drain reports an offline source and normal authorized restart permits catch-up", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "retained"}}, scope: scope(ctx.publisher))
    Domain.source_stop!(source, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])

    await_state_value(writer.pid, fn runtime ->
      if hd(runtime.agent.state.journal_consumer.sources).status == :unavailable, do: true
    end)

    receipt = Domain.writer_drain_journals!(writer, %{}, scope: scope(ctx.writer_actor))
    consumer = snapshot(writer).journal_consumer
    assert consumer.paused?
    assert is_nil(consumer.drained_request_id)
    assert is_nil(consumer.drain_request_id)
    refute consumer.drained_request_id == receipt.signal_id
    assert hd(consumer.sources).status == :unavailable

    restored = start_source(ctx.publisher)

    Domain.writer_retry_journal!(writer, %{source: reference(restored)},
      scope: scope(ctx.writer_actor)
    )

    Domain.writer_continue_journals!(writer, %{}, scope: scope(ctx.writer_actor))
    work = await_work(writer, ["retained"])
    commit(writer, work, ctx.writer_actor)

    assert {:ok, _} =
             Aikido.AgentServer.call_until(
               writer.pid,
               fn ->
                 Domain.writer_drain_journals(writer, %{}, scope: scope(ctx.writer_actor))
               end,
               "aikido.thread.consumer.drained",
               fn runtime ->
                 consumer = runtime.agent.state.journal_consumer

                 if consumer.paused? && consumer.drained_request_id,
                   do: {:ok, consumer},
                   else: :skip
               end
             )
  end

  test "immutable entry IDs ignore identical retries and reject conflicts including after pruning",
       ctx do
    source = start_source(ctx.publisher)
    entry = %{id: "immutable", at: 10, payload: %{text: "first"}}
    Domain.source_append!(source, %{entry: entry}, scope: scope(ctx.publisher))
    initial = snapshot(source).thread
    Domain.source_append!(source, %{entry: entry}, scope: scope(ctx.publisher))
    assert snapshot(source).thread == initial

    assert {:error, _} =
             Domain.source_append(source, %{entry: %{entry | payload: %{text: "conflict"}}},
               scope: scope(ctx.publisher)
             )

    assert snapshot(source).thread == initial
    Domain.source_prune!(source, %{through_sequence: 0}, scope: scope(ctx.publisher))
    pruned = snapshot(source).thread
    assert pruned.entries == []
    Domain.source_append!(source, %{entry: entry}, scope: scope(ctx.publisher))
    assert snapshot(source).thread == pruned

    assert {:error, _} =
             Domain.source_append(source, %{entry: %{entry | payload: %{text: "conflict"}}},
               scope: scope(ctx.publisher)
             )
  end

  test "generated and direct no-op Follow and Ack remain denied after read permission is revoked",
       ctx do
    source = start_source(ctx.publisher)

    Domain.source_append!(source, %{entry: %{id: "private", payload: %{text: "private"}}},
      scope: scope(ctx.publisher)
    )

    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["private"])
    thread = snapshot(source).thread
    [follower] = thread.followers

    arguments = %{
      consumer: reference(writer),
      path: :thread,
      after: follower.cursor,
      batch_size: 2
    }

    Domain.source_follow!(source, arguments, scope: scope(ctx.writer_actor))
    assert snapshot(source).thread == thread

    access = Ash.get!(Aikido.ThreadFollowTest.Access, ctx.writer_actor.id, authorize?: false)
    Ash.update!(access, %{reader?: false}, authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.source_follow(source, arguments, scope: scope(ctx.writer_actor))

    follow = Aikido.Thread.Signals.Follow.new!(arguments, scope: scope(ctx.writer_actor))

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(source.pid, follow, &{:ok, &1.agent.state.thread})

    ack = %{
      consumer: reference(writer),
      path: :thread,
      batch_id: "wrong-offer",
      cursor:
        Aikido.Thread.Types.Cursor.new!(
          generation: work.batch.generation,
          sequence: work.batch.last_sequence
        )
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.source_ack(source, ack, scope: scope(ctx.writer_actor))

    signal = Aikido.Thread.Signals.Ack.new!(ack, scope: scope(ctx.writer_actor))

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(source.pid, signal, &{:ok, &1.agent.state.thread})

    assert snapshot(source).thread == thread
    assert snapshot(writer).works_received == 1
  end

  test "clear and pruning report explicit gaps instead of silently advancing a consumer", ctx do
    source = start_source(ctx.publisher)

    Domain.source_append!(source, %{entry: [%{id: "a"}, %{id: "b"}, %{id: "c"}]},
      scope: scope(ctx.publisher)
    )

    writer = start_writer(ctx.writer_actor, [reference(source)])
    await_work(writer, ["a", "b"])
    Domain.source_prune!(source, %{through_sequence: 1}, scope: scope(ctx.publisher))

    await_state_value(writer.pid, fn runtime ->
      case runtime.agent.state.journal_consumer.sources do
        [%{status: :gap}] -> true
        _ -> nil
      end
    end)

    assert hd(snapshot(writer).journal_consumer.sources).cursor.sequence == -1
    clear = Domain.source_clear!(source, %{}, scope: scope(ctx.publisher))
    assert snapshot(source).thread.last_clear_id == clear.signal_id
  end

  test "retrying Clear after an append and consumer commit does not reuse sequence zero", ctx do
    source = start_source(ctx.publisher)
    clear = Aikido.Thread.Signals.Clear.new!(%{}, scope: scope(ctx.publisher))
    assert {:ok, _} = Aikido.AgentServer.call(source.pid, clear, &{:ok, &1.agent.state.thread})
    Domain.source_append!(source, %{entry: %{id: "before-retry"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["before-retry"])
    commit(writer, work, ctx.writer_actor)
    before_retry = snapshot(source).thread

    assert {:ok, _} = Aikido.AgentServer.call(source.pid, clear, &{:ok, &1.agent.state.thread})
    after_retry = snapshot(source).thread
    assert after_retry.generation == before_retry.generation
    assert after_retry.entries == before_retry.entries
    assert after_retry.next_sequence == before_retry.next_sequence

    Domain.source_append!(source, %{entry: %{id: "after-retry"}}, scope: scope(ctx.publisher))
    next = await_work(writer, ["after-retry"])
    assert next.batch.generation == work.batch.generation
    assert next.batch.first_sequence == 1
  end

  test "a public cursor reset is rejected while SQL work is outstanding", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "writing"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["writing"])
    before_reset = snapshot(writer).journal_consumer

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.writer_watch_journal(writer, %{source: reference(source), reset?: true},
               scope: scope(ctx.writer_actor)
             )

    assert Enum.any?(error.errors, &match?(%Ash.Error.Action.InvalidArgument{field: :after}, &1))
    assert Exception.message(error) =~ "Cannot reset a journal cursor"
    after_reset = snapshot(writer).journal_consumer
    assert after_reset.credits == before_reset.credits

    assert Enum.map(after_reset.sources, & &1.cursor) ==
             Enum.map(before_reset.sources, & &1.cursor)

    commit(writer, work, ctx.writer_actor)

    await_state_value(writer.pid, fn runtime ->
      case runtime.agent.state.journal_consumer.sources do
        [%{cursor: %{sequence: 0}}] -> true
        _ -> nil
      end
    end)

    await_state_value(writer.pid, fn runtime ->
      if runtime.agent.state.journal_consumer.credits == [], do: true
    end)

    assert {:ok, _} =
             Domain.writer_watch_journal(writer, %{source: reference(source), reset?: true},
               scope: scope(ctx.writer_actor)
             )

    settled =
      await_state_value(writer.pid, fn runtime ->
        own = Aikido.Agent.resource_attributes(runtime.agent)
        consumer = runtime.agent.state.journal_consumer

        if own.works_received == 2 ||
             Enum.any?(consumer.sources, &(&1.status in [:failed, :rejected, :gap, :unavailable])),
           do: %{works_received: own.works_received, sources: consumer.sources}
      end)

    assert %{works_received: 2} = settled
  end

  test "a public cursor reset also rejects an outstanding source request", ctx do
    source =
      Domain.pending_source_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    writer = start_writer(ctx.writer_actor, [])

    assert {:ok, _} =
             Domain.writer_watch_journal(writer, %{source: reference(source)},
               scope: scope(ctx.writer_actor)
             )

    assert [%{phase: :requesting}] = snapshot(writer).journal_consumer.credits

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.writer_watch_journal(writer, %{source: reference(source), reset?: true},
               scope: scope(ctx.writer_actor)
             )

    assert Enum.any?(error.errors, &match?(%Ash.Error.Action.InvalidArgument{field: :after}, &1))
    assert Exception.message(error) =~ "Cannot reset a journal cursor"
    assert [%{phase: :requesting}] = snapshot(writer).journal_consumer.credits
  end

  test "restoring a consumer replays from its saved committed cursor without storing process addresses",
       ctx do
    source = start_source(ctx.publisher)

    Domain.source_append!(source, %{entry: [%{id: "a"}, %{id: "b"}, %{id: "c"}]},
      scope: scope(ctx.publisher)
    )

    writer = start_writer(ctx.writer_actor, [reference(source)])
    first = await_work(writer, ["a", "b"])
    commit(writer, first, ctx.writer_actor)
    await_work(writer, ["c"])
    Domain.writer_stop!(writer, scope: scope(ctx.writer_actor))
    restored = start_writer(ctx.writer_actor, [reference(source)])
    await_work(restored, ["c"])

    saved =
      :sys.get_state(restored.pid).user_state
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

    refute inspect(saved, limit: :infinity) =~ "#PID<"
    refute inspect(saved, limit: :infinity) =~ "allowed: true"
  end

  test "a late storage member discovers retained team sources from its parent roster", ctx do
    team =
      Domain.journal_team_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    Domain.journal_team_add_member!(
      team,
      %{member: :history, template: :source, initial_state: %{thread: %{replay?: true}}},
      scope: scope(ctx.publisher)
    )

    history = snapshot(team).team.members.history

    Domain.source_append!(
      history,
      %{entry: %{id: "before-storage", at: 100, payload: %{text: "retained"}}},
      scope: scope(ctx.publisher)
    )

    Domain.journal_team_add_member!(
      team,
      %{
        member: :storage,
        template: :writer,
        initial_state: %{
          actor_id: ctx.writer_actor.id,
          journal_consumer: %{
            follow_parent?: true,
            batch_size: 2,
            window: 1,
            request_timeout_ms: 60_000
          }
        }
      },
      scope: scope(ctx.publisher)
    )

    pid = snapshot(team).team.members.storage
    writer = %{pid: pid, id: "#{team.id}/storage", resource: Aikido.ThreadFollowTest.Writer}
    work = drain_until_entry(writer, ctx.writer_actor, "before-storage", 0, 12)
    assert work.channel == :thread
    assert [%{id: "before-storage", at: 100}] = work.entries
    assert snapshot(writer).last_actor == ctx.writer_actor.id
  end

  test "sink retries are opt-in and permanent failures never schedule replay", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "retry-disabled"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])
    work = await_work(writer, ["retry-disabled"])

    fail_work(writer, work, ctx.writer_actor, 3_600_000)
    [failed] = snapshot(writer).journal_consumer.sources
    assert failed.status == :failed
    assert failed.retry_attempt == 0
    assert failed.retry_id == nil

    Domain.writer_configure_journal_retry!(writer, %{retry_limit: 3},
      scope: scope(ctx.writer_actor)
    )

    Domain.writer_retry_journal!(writer, Map.take(work, [:source, :path, :channel]),
      scope: scope(ctx.writer_actor)
    )

    work = await_work_count(writer, 2)
    fail_work(writer, work, ctx.writer_actor, nil)
    [failed] = snapshot(writer).journal_consumer.sources
    assert failed.status == :failed
    assert failed.retry_attempt == 0
    assert failed.retry_at == nil
  end

  test "automatic sink retries are finite and stale deadlines cannot bypass manual reset", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "retry-bounded"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])

    Domain.writer_configure_journal_retry!(writer, %{retry_limit: 3},
      scope: scope(ctx.writer_actor)
    )

    work = await_work(writer, ["retry-bounded"])

    work =
      Enum.reduce(1..3, work, fn attempt, offered ->
        fail_work(writer, offered, ctx.writer_actor, 3_600_000)
        [retrying] = snapshot(writer).journal_consumer.sources
        assert retrying.status == :retrying
        assert retrying.retry_attempt == attempt
        assert snapshot(writer).journal_consumer.credits == []
        deliver_retry_due(writer, retrying, ctx.writer_actor)
        next = await_work_count(writer, attempt + 1)
        assert next.retry_attempt == attempt
        next
      end)

    fail_work(writer, work, ctx.writer_actor, 3_600_000)
    [failed] = snapshot(writer).journal_consumer.sources
    assert failed.status == :failed
    assert failed.retry_attempt == 3
    assert failed.retry_id == nil
    assert snapshot(writer).works_received == 4

    Domain.writer_retry_journal!(writer, Map.take(work, [:source, :path, :channel]),
      scope: scope(ctx.writer_actor)
    )

    next = await_work_count(writer, 5)
    assert next.retry_attempt == 0
    fail_work(writer, next, ctx.writer_actor, 3_600_000)
    [stale] = snapshot(writer).journal_consumer.sources

    Domain.writer_retry_journal!(writer, Map.take(work, [:source, :path, :channel]),
      scope: scope(ctx.writer_actor)
    )

    final = await_work_count(writer, 6)
    deliver_retry_due(writer, stale, ctx.writer_actor)
    assert snapshot(writer).works_received == 6
    assert [%{phase: :writing}] = snapshot(writer).journal_consumer.credits
    commit(writer, final, ctx.writer_actor)
    [settled] = snapshot(writer).journal_consumer.sources
    assert settled.retry_attempt == 0
    assert settled.retry_id == nil
  end

  test "the actual native Schedule delivery advances a sink retry", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "retry-timer"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])

    Domain.writer_configure_journal_retry!(writer, %{retry_limit: 1},
      scope: scope(ctx.writer_actor)
    )

    work = await_work(writer, ["retry-timer"])
    fail_work(writer, work, ctx.writer_actor, 1)
    retried = await_work_count(writer, 2)
    assert retried.retry_attempt == 1
    assert retried.entries == work.entries
    assert [%{phase: :writing}] = snapshot(writer).journal_consumer.credits
    commit(writer, retried, ctx.writer_actor)
  end

  test "restart preserves a pending sink retry count and deadline", ctx do
    source = start_source(ctx.publisher)
    Domain.source_append!(source, %{entry: %{id: "retry-restored"}}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [reference(source)])

    Domain.writer_configure_journal_retry!(writer, %{retry_limit: 3},
      scope: scope(ctx.writer_actor)
    )

    work = await_work(writer, ["retry-restored"])
    fail_work(writer, work, ctx.writer_actor, 3_600_000)
    [pending] = snapshot(writer).journal_consumer.sources
    Domain.writer_stop!(writer, scope: scope(ctx.writer_actor))
    restored = start_writer(ctx.writer_actor, [reference(source)])
    [retained] = snapshot(restored).journal_consumer.sources
    assert retained.retry_attempt == pending.retry_attempt
    assert retained.retry_id == pending.retry_id
    assert retained.retry_at == pending.retry_at
    assert retained.status == :retrying
    assert snapshot(restored).journal_consumer.credits == []
    deliver_retry_due(restored, retained, ctx.writer_actor)
    next = await_work_count(restored, 2)
    assert next.retry_attempt == 1
    commit(restored, next, ctx.writer_actor)
    [settled] = snapshot(restored).journal_consumer.sources
    assert settled.retry_attempt == 0
  end

  defp fail_work(writer, work, actor, delay) do
    data =
      work
      |> Map.take([:source, :path, :channel, :batch])
      |> Map.merge(%{message: "public sink failure", retry_after_ms: delay})

    signal = Aikido.Thread.Consumer.Signals.Failed.new!(data, scope: scope(actor))

    assert {:ok, :failed} =
             Aikido.AgentServer.call(writer.pid, signal, fn _ -> {:ok, :failed} end)
  end

  defp deliver_retry_due(writer, source, actor) do
    signal =
      Aikido.Thread.Consumer.Signals.RetryDue.new!(
        %{
          source: source.source,
          path: source.path,
          channel: source.channel,
          retry_id: source.retry_id,
          generation: source.retry_generation
        },
        scope: scope(actor),
        time: DateTime.from_unix!(source.retry_at, :millisecond) |> DateTime.to_iso8601()
      )

    assert {:ok, :due} = Aikido.AgentServer.call(writer.pid, signal, fn _ -> {:ok, :due} end)
  end

  defp await_work_count(writer, count) do
    await_state_value(
      writer.pid,
      fn runtime ->
        own = Aikido.Agent.resource_attributes(runtime.agent)
        if own.works_received == count, do: own.last_work
      end,
      timeout: 5_000
    )
  end

  test "a retained nil roster journal bootstraps its actual current live membership", ctx do
    team =
      Domain.optional_roster_team_start!(
        %{
          id: ctx.publisher.id,
          actor_id: ctx.publisher.id
        },
        scope: scope(ctx.publisher)
      )

    Domain.optional_roster_team_add_member!(
      team,
      %{member: :existing, template: :source, initial_state: %{thread: %{replay?: true}}},
      scope: scope(ctx.publisher)
    )

    assert snapshot(team).team.membership_journal == nil
    Domain.optional_roster_team_stop!(team, scope: scope(ctx.publisher))

    restored =
      Domain.optional_roster_team_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    Domain.optional_roster_team_reconcile!(restored, %{}, scope: scope(ctx.publisher))

    retained =
      await_state_value(
        restored.pid,
        fn runtime ->
          team = runtime.agent.state.team
          if is_pid(team.members[:existing]), do: team
        end,
        timeout: 5_000
      )

    assert is_pid(retained.members.existing)
    assert retained.membership_journal == nil

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.optional_roster_team_configure_roster_replay(
               restored,
               %{metadata: %{routing: %{storage: "writer"}}},
               scope: scope(ctx.writer_actor)
             )

    assert snapshot(restored).team.membership_journal == nil

    Domain.optional_roster_team_configure_roster_replay!(restored, %{metadata: %{user: "keep"}},
      scope: scope(ctx.publisher)
    )

    initialized = snapshot(restored).team.membership_journal
    assert initialized.replay?
    assert is_binary(initialized.generation)
    assert [%{kind: :roster}] = initialized.entries

    Domain.optional_roster_team_configure_roster_replay!(
      restored,
      %{metadata: %{routing: %{storage: "writer"}}},
      scope: scope(ctx.publisher)
    )

    configured = snapshot(restored).team.membership_journal
    assert configured.generation == initialized.generation
    assert configured.metadata == %{user: "keep", routing: %{storage: "writer"}}

    Domain.optional_roster_team_add_member!(
      restored,
      %{member: :later, template: :source, initial_state: %{thread: %{replay?: true}}},
      scope: scope(ctx.publisher)
    )

    writer = start_writer(ctx.writer_actor, [])

    Domain.writer_watch_journal!(
      writer,
      %{source: reference(restored), path: :team, channel: :roster},
      scope: scope(ctx.writer_actor)
    )

    work =
      await_state_value(
        writer.pid,
        fn runtime ->
          work = Aikido.Agent.resource_attributes(runtime.agent).last_work
          if work && work.channel == :roster, do: work
        end,
        timeout: 5_000
      )

    assert [%{kind: :roster, payload: %{event: :bootstrap, members: [member]}} | _] = work.entries
    assert member.name == :existing
    assert member.active?
    assert member.incarnation == retained.incarnations.existing
    assert member.reference.id == "#{restored.id}/existing"
    assert member.reference.resource == Aikido.ThreadFollowTest.Source
    discovered = Enum.map(snapshot(writer).journal_consumer.sources, & &1.source.id)
    assert "#{restored.id}/existing" in discovered
    assert "#{restored.id}/later" in discovered
    assert work.metadata == configured.metadata
    assert snapshot(restored).team.membership_journal.generation == initialized.generation
  end

  defp drain_until_entry(_writer, _actor, _id, _count, 0),
    do: flunk("Retained entry was not discovered through roster replay")

  defp drain_until_entry(writer, actor, id, count, remaining) do
    {next_count, work} =
      await_state_value(
        writer.pid,
        fn runtime ->
          own = Aikido.Agent.resource_attributes(runtime.agent)
          if own.works_received > count, do: {own.works_received, own.last_work}
        end,
        timeout: 5_000
      )

    if Enum.any?(work.entries, &(&1.id == id)) do
      work
    else
      commit(writer, work, actor)
      drain_until_entry(writer, actor, id, next_count, remaining - 1)
    end
  end

  defp actor(role) do
    actor = %{id: Ash.UUIDv7.generate(), allowed: true}

    Ash.create!(
      Aikido.ThreadFollowTest.Access,
      %{id: actor.id, role: role, reader?: role == :writer},
      authorize?: false
    )

    actor
  end

  defp scope(actor), do: %{actor: actor, tenant: "journal-test"}

  defp start_source(actor),
    do:
      Domain.source_start!(
        %{id: actor.id, actor_id: actor.id, thread: %{retry_ms: 60_000, replay?: true}},
        scope: scope(actor)
      )

  defp start_writer(actor, roots),
    do:
      Domain.writer_start!(
        %{
          id: actor.id,
          actor_id: actor.id,
          journal_consumer: %{
            roots: roots,
            follow_parent?: false,
            batch_size: 2,
            window: 1,
            request_timeout_ms: 60_000
          }
        },
        scope: scope(actor)
      )

  defp reference(agent),
    do: Reference.new!(id: agent.id, resource: agent.resource, aikido: Aikido.Default)

  defp snapshot(agent) do
    assert {:ok, state} =
             Aikido.AgentServer.state(
               agent.pid,
               &{:ok, Aikido.Agent.resource_attributes(&1.agent)}
             )

    state
  end

  defp await_work(writer, ids) do
    await_state_value(
      writer.pid,
      fn runtime ->
        work = Aikido.Agent.resource_attributes(runtime.agent).last_work
        if work && Enum.map(work.entries, & &1.id) == ids, do: work
      end,
      timeout: 5_000
    )
  end

  defp commit(writer, work, actor) do
    data = Map.take(work, [:source, :path, :channel, :batch])
    signal = Aikido.Thread.Consumer.Signals.Committed.new!(data, scope: scope(actor))

    assert {:ok, :committed} =
             Aikido.AgentServer.call(writer.pid, signal, fn _runtime -> {:ok, :committed} end)
  end
end
