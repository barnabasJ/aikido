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

  test "lazy declarations in a real roster bootstrap create no demand until actual start", ctx do
    topology =
      Map.new([:coder, :reviewer], fn name ->
        {name,
         %{
           resource: Aikido.ThreadFollowTest.JournalSquad,
           activation: :lazy,
           initial_state: %{thread: %{replay?: true, retry_ms: 60_000}}
         }}
      end)

    team =
      Domain.optional_roster_team_start!(
        %{id: ctx.publisher.id, actor_id: ctx.publisher.id, topology: topology},
        scope: scope(ctx.publisher)
      )

    Domain.optional_roster_team_configure_roster_replay!(team, %{}, scope: scope(ctx.publisher))
    writer = start_writer(ctx.writer_actor, [])

    Domain.writer_watch_journal!(
      writer,
      %{source: reference(team), path: :team, channel: :roster},
      scope: scope(ctx.writer_actor)
    )

    bootstrap = await_work_count(writer, 1)
    assert [%{kind: :roster, payload: %{members: members}}] = bootstrap.entries
    assert Enum.sort(Enum.map(members, & &1.name)) == [:coder, :reviewer]
    assert Enum.all?(members, &(!&1.active?))
    assert Enum.all?(snapshot(writer).journal_consumer.sources, &(&1.source == reference(team)))
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    assert :error = Aikido.Durable.lookup(pool, "#{team.id}/coder")
    assert :error = Aikido.Durable.lookup(pool, "#{team.id}/reviewer")
    commit(writer, bootstrap, ctx.writer_actor)

    assert {:ok, consumer} =
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

    assert [%{channel: :roster, status: :watching}] = consumer.sources
    assert consumer.credits == []
    Domain.writer_continue_journals!(writer, %{}, scope: scope(ctx.writer_actor))

    Domain.optional_roster_team_ensure_member!(team, %{member: :coder},
      scope: scope(ctx.publisher)
    )

    started = await_work_count(writer, 2)

    assert Enum.any?(
             started.entries,
             &(&1.kind == :membership && &1.payload.event == :started && &1.payload.active?)
           )

    coder = %{
      id: "#{team.id}/coder",
      pid: snapshot(team).team.members.coder,
      resource: Aikido.ThreadFollowTest.JournalSquad
    }

    discovered =
      Enum.filter(snapshot(writer).journal_consumer.sources, &(&1.source == reference(coder)))

    assert Enum.sort(Enum.map(discovered, & &1.channel)) == [:roster, :thread]

    refute Enum.any?(
             snapshot(writer).journal_consumer.sources,
             &(&1.source.id == "#{team.id}/reviewer")
           )

    commit(writer, started, ctx.writer_actor)
    squad_roster = await_work_count(writer, 3)
    assert squad_roster.channel == :roster
    assert squad_roster.source == reference(coder)

    Domain.journal_squad_append!(coder, %{entry: %{id: "live-coder"}},
      scope: scope(ctx.publisher)
    )

    commit(writer, squad_roster, ctx.writer_actor)
    assert await_work(writer, ["live-coder"]).source == reference(coder)
    assert :error = Aikido.Durable.lookup(pool, "#{team.id}/reviewer")
  end

  test "a lazy added membership entry does not follow either declared journal channel", ctx do
    team =
      Domain.journal_team_start!(%{id: ctx.publisher.id, actor_id: ctx.publisher.id},
        scope: scope(ctx.publisher)
      )

    writer = start_writer(ctx.writer_actor, [reference(team)])
    commit(writer, await_work_count(writer, 1), ctx.writer_actor)

    Domain.journal_team_add_member!(
      team,
      %{
        member: :lazy,
        resource: Aikido.ThreadFollowTest.JournalSquad,
        activation: :lazy,
        initial_state: %{thread: %{replay?: true}}
      },
      scope: scope(ctx.publisher)
    )

    added = await_work_count(writer, 2)
    assert [%{kind: :membership, payload: %{event: :added, active?: false}}] = added.entries
    assert Enum.all?(snapshot(writer).journal_consumer.sources, &(&1.source == reference(team)))
    commit(writer, added, ctx.writer_actor)

    await_state_value(writer.pid, fn runtime ->
      consumer = runtime.agent.state.journal_consumer

      if consumer.credits == [] && Enum.all?(consumer.sources, &(&1.status == :watching)),
        do: true
    end)

    assert :error =
             Aikido.Durable.lookup(
               Aikido.durable_supervisor_name(Aikido.Default),
               "#{team.id}/lazy"
             )
  end

  test "retired source debt and its cursor survive removal and consumer restoration", ctx do
    team =
      Domain.journal_team_start!(
        %{
          id: ctx.publisher.id,
          actor_id: ctx.publisher.id,
          topology: %{
            worker: %{
              resource: Aikido.ThreadFollowTest.Source,
              initial_state: %{thread: %{replay?: true, retry_ms: 60_000}}
            }
          }
        },
        scope: scope(ctx.publisher)
      )

    source = %{
      id: "#{team.id}/worker",
      pid: snapshot(team).team.members.worker,
      resource: Aikido.ThreadFollowTest.Source
    }

    Domain.source_append!(source, %{entry: [%{id: "debt-a"}, %{id: "debt-b"}]},
      scope: scope(ctx.publisher)
    )

    writer =
      Domain.writer_start!(
        %{
          id: ctx.writer_actor.id,
          actor_id: ctx.writer_actor.id,
          journal_consumer: %{
            roots: [reference(team)],
            follow_parent?: false,
            batch_size: 2,
            window: 2,
            paused?: true,
            request_timeout_ms: 60_000
          }
        },
        scope: scope(ctx.writer_actor)
      )

    {:ok, roster_ref} =
      Aikido.AgentServer.subscribe(
        writer.pid,
        "aikido.thread.consumer.work",
        fn _, event ->
          if event.signal.data.channel == :roster, do: {:ok, event.signal.data}, else: :skip
        end,
        once: true
      )

    {:ok, debt_ref} =
      Aikido.AgentServer.subscribe(
        writer.pid,
        "aikido.thread.consumer.work",
        fn _, event ->
          if event.signal.data.channel == :thread, do: {:ok, event.signal.data}, else: :skip
        end,
        once: true
      )

    Domain.writer_continue_journals!(writer, %{}, scope: scope(ctx.writer_actor))
    assert_receive {:aikido_subscription, ^roster_ref, %{result: {:ok, roster}}}, 5_000
    commit(writer, roster, ctx.writer_actor)
    assert_receive {:aikido_subscription, ^debt_ref, %{result: {:ok, debt}}}, 5_000
    assert Enum.map(debt.entries, & &1.id) == ["debt-a", "debt-b"]

    before =
      Enum.find(snapshot(writer).journal_consumer.sources, &(&1.source == reference(source)))

    Domain.journal_team_remove_member!(team, %{member: :worker}, scope: scope(ctx.publisher))

    removed =
      await_state_value(writer.pid, fn runtime ->
        work = Aikido.Agent.resource_attributes(runtime.agent).last_work

        if work && work.channel == :roster &&
             Enum.any?(work.entries, &(&1.kind == :membership && &1.payload.event == :removed)),
           do: work
      end)

    assert [%{payload: %{reference: removed_reference, active?: false}}] = removed.entries
    assert removed_reference == reference(source)

    stopped =
      Enum.find(snapshot(writer).journal_consumer.sources, &(&1.source == reference(source)))

    assert stopped.retired?
    assert stopped.cursor == before.cursor

    assert Enum.any?(
             snapshot(writer).journal_consumer.credits,
             &(&1.phase == :writing && &1.batch == debt.batch)
           )

    commit(writer, removed, ctx.writer_actor)
    Domain.writer_stop!(writer, scope: scope(ctx.writer_actor))
    restored = start_writer(ctx.writer_actor, [reference(team)])

    unavailable =
      await_state_value(restored.pid, fn runtime ->
        Enum.find(
          runtime.agent.state.journal_consumer.sources,
          &(&1.source == reference(source) && &1.status == :unavailable)
        )
      end)

    assert unavailable.retired?
    assert unavailable.cursor == before.cursor

    assert :error =
             Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), source.id)

    {:ok, replay_ref} =
      Aikido.AgentServer.subscribe(
        restored.pid,
        "aikido.thread.consumer.work",
        fn _, event ->
          if event.signal.data.source == reference(source) && event.signal.data.channel == :thread,
            do: {:ok, event.signal.data},
            else: :skip
        end,
        once: true
      )

    Domain.journal_team_add_member!(
      team,
      %{member: :worker, template: :source, initial_state: %{thread: %{replay?: true}}},
      scope: scope(ctx.publisher)
    )

    assert_receive {:aikido_subscription, ^replay_ref, %{result: {:ok, replayed}}}, 5_000
    assert replayed.batch == debt.batch
    assert Enum.map(replayed.entries, & &1.id) == ["debt-a", "debt-b"]

    assert Enum.find(
             snapshot(restored).journal_consumer.sources,
             &(&1.source == reference(source))
           ).cursor == before.cursor
  end

  test "a desired replacement does not borrow the old process's active incarnation", ctx do
    team =
      Domain.journal_team_start!(
        %{
          id: ctx.publisher.id,
          actor_id: ctx.publisher.id,
          topology: %{
            worker: %{
              resource: Aikido.ThreadFollowTest.TransientSource,
              initial_state: %{thread: %{replay?: true}}
            }
          }
        },
        scope: scope(ctx.publisher)
      )

    writer = start_writer(ctx.writer_actor, [reference(team)])
    commit(writer, await_work_count(writer, 1), ctx.writer_actor)

    await_state_value(writer.pid, fn runtime ->
      consumer = runtime.agent.state.journal_consumer

      if consumer.credits == [] && Enum.all?(consumer.sources, &(&1.status == :watching)),
        do: true
    end)

    Process.register(self(), Aikido.ThreadFollowTest.SquadStartObserver)

    task =
      Task.async(fn ->
        Domain.journal_team_configure_topology(
          team,
          %{
            topology: %{
              worker: %{
                resource: Aikido.ThreadFollowTest.JournalSquad,
                initial_state: %{thread: %{replay?: true}}
              }
            }
          },
          scope: scope(ctx.publisher)
        )
      end)

    assert_receive {:squad_start_waiting, replacement}, 5_000
    on_exit(fn -> send(replacement, :continue_squad_start) end)
    replaced = await_work_count(writer, 2)

    assert [
             %{
               payload: %{
                 event: :replaced,
                 active?: false,
                 incarnation: nil,
                 reference: new_reference,
                 previous_reference: old_reference
               }
             }
           ] = replaced.entries

    assert old_reference.resource == Aikido.ThreadFollowTest.TransientSource
    assert new_reference.resource == Aikido.ThreadFollowTest.JournalSquad
    refute Enum.any?(snapshot(writer).journal_consumer.sources, &(&1.source == new_reference))
    journal = snapshot(team).team.membership_journal

    stopped =
      Enum.find(journal.entries, &(&1.kind == :membership && &1.payload.event == :stopped))

    assert stopped.payload.reference == old_reference
    send(replacement, :continue_squad_start)
    assert {:ok, _} = Task.await(task, 5_000)

    current = %{
      id: "#{team.id}/worker",
      pid: snapshot(team).team.members.worker,
      resource: Aikido.ThreadFollowTest.JournalSquad
    }

    Domain.journal_squad_append!(current, %{entry: %{id: "replacement-live"}},
      scope: scope(ctx.publisher)
    )

    commit(writer, replaced, ctx.writer_actor)

    work =
      try do
        drain_until_entry(writer, ctx.writer_actor, "replacement-live", 2, 12)
      rescue
        error in ExUnit.AssertionError ->
          flunk(
            "#{Exception.message(error)} Consumer: #{inspect(snapshot(writer).journal_consumer, limit: :infinity)}"
          )
      end

    assert work.source == new_reference

    retired = Enum.find(snapshot(writer).journal_consumer.sources, &(&1.source == old_reference))
    assert retired.retired?
    assert retired.status == :rejected
    assert retired.error =~ "different resource"
    assert retired.cursor.sequence == -1
    assert retired.cursor.generation != work.batch.generation
  end

  test "an address-mismatch rejection cannot claim a different durable key", ctx do
    source = start_source(ctx.publisher)
    writer = start_writer(ctx.writer_actor, [reference(source)])

    other =
      Domain.journal_squad_start!(
        %{id: Ash.UUIDv7.generate(), actor_id: ctx.publisher.id, thread: %{replay?: true}},
        scope: scope(ctx.publisher)
      )

    sender = reference(other) |> Map.from_struct() |> Map.put(:pid, other.pid)

    rejected =
      Aikido.Thread.Signals.Rejected.new!(%{
        source: reference(source),
        consumer: reference(writer),
        path: :thread,
        channel: :thread,
        request_id: "fabricated",
        request_type: "aikido.thread.follow",
        failure: :invalid,
        message: "not this source"
      })

    assert {:ok, false} =
             Aikido.AgentServer.state(writer.pid, fn runtime ->
               {:ok,
                Aikido.Thread.Delivery.permitted?(runtime, sender, rejected, %{
                  kind: :batch,
                  address_mismatch?: true
                })}
             end)

    writer_sender = reference(writer) |> Map.from_struct() |> Map.put(:pid, writer.pid)

    target =
      Reference.new!(
        id: other.id,
        resource: Aikido.ThreadFollowTest.Source,
        aikido: Aikido.Default
      )

    malformed = %Aikido.Signal{
      id: Ash.UUIDv7.generate(),
      type: "aikido.thread.follow",
      data: %{consumer: reference(writer), path: %{invalid: true}}
    }

    send(
      other.pid,
      {Aikido.Signal.Delivery, Aikido.Thread.Delivery, writer_sender, malformed,
       %{kind: :request, target: target}}
    )

    assert {:ok, :alive} = Aikido.AgentServer.state(other.pid, fn _ -> {:ok, :alive} end)
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

    Domain.writer_retry_journal!(writer, Map.take(work, [:source, :path, :channel]),
      scope: scope(ctx.writer_actor)
    )

    work = await_work_count(writer, 3)
    data = work |> Map.take([:source, :path, :channel, :batch]) |> Map.put(:message, "permanent")
    refute Map.has_key?(data, :retry_after_ms)
    Domain.writer_failed!(writer, data, scope: scope(ctx.writer_actor))
    [failed] = snapshot(writer).journal_consumer.sources
    assert failed.status == :failed
    assert failed.retry_attempt == 0
    assert snapshot(writer).journal_consumer.credits == []
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
      |> Map.put(:message, "public sink failure")
      |> then(fn data ->
        if is_nil(delay), do: data, else: Map.put(data, :retry_after_ms, delay)
      end)

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
    previous_child = snapshot(team).team.members.existing
    Domain.optional_roster_team_stop!(team, scope: scope(ctx.publisher))
    AikidoTest.LifecycleWait.await_down(previous_child, 5_000)

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
    refute "#{restored.id}/later" in discovered
    commit(writer, work, ctx.writer_actor)
    started = await_work_count(writer, 2)

    assert Enum.any?(started.entries, fn entry ->
             entry.kind == :membership && entry.payload.event == :started && entry.payload.active? &&
               entry.payload.name == :later
           end)

    assert Enum.any?(
             snapshot(writer).journal_consumer.sources,
             &(&1.source.id == "#{restored.id}/later")
           )

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
