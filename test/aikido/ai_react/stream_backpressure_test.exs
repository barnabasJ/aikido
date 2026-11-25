defmodule Aikido.StreamBackpressureTest.Gate do
  use Aikido.Middleware

  @impl true
  def on_signal(%{type: "ai.react.stream"} = signal, ctx, _opts, next) do
    actor = ctx.actor || %{}

    if actor[:observer] do
      if signal.data.sequence == 1 && actor[:gate] do
        send(actor.observer, {:batch_waiting, self(), signal.data})

        receive do
          :release_batch -> :ok
        end
      end

      if actor[:reject] do
        {:error, ctx, :synthetic_rejection}
      else
        result = next.(signal, ctx)
        send(actor.observer, {:batch_processed, signal.data.sequence})
        result
      end
    else
      next.(signal, ctx)
    end
  end

  def on_signal(%{type: "ai.react.llm.completed"} = signal, ctx, _opts, next) do
    if ctx.actor[:observer],
      do:
        send(
          ctx.actor.observer,
          {:terminal_processing, ctx.agent.state.ai.stream_receipt.sequence}
        )

    next.(signal, ctx)
  end

  def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
end

defmodule Aikido.StreamBackpressureTest.Agent do
  use Aikido.Agent

  agent do
    name "stream_backpressure"
    middleware [Aikido.StreamBackpressureTest.Gate]
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.StreamBackpressureTest.NamedAgent do
  use Aikido.Agent

  agent do
    name "named_stream_backpressure"
    slice :model, Aikido.AiReact.Slice
    slice :other, Aikido.AiReact.Slice
  end
end

defmodule Aikido.StreamBackpressureTest.Client do
  def stream_text(_, messages, opts) do
    observer = opts[:observer]
    size = opts[:size]
    send(observer, {:stream_open, self()})

    {:ok, metadata} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

    stream =
      Stream.map(1..size, fn index ->
        if index in [1, 64, 65, 128, 129, size], do: send(observer, {:pulled, index})
        ReqLLM.StreamChunk.text("x")
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: stream,
       metadata_handle: metadata,
       cancel: fn -> send(observer, :stream_closed) end,
       model: %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"},
       context: ReqLLM.Context.new(messages)
     }}
  end
end

defmodule Aikido.StreamBackpressureTest.NativeQueueClient do
  def stream_text(_, messages, opts) do
    observer = opts[:observer]
    model = %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"}

    {:ok, server} =
      ReqLLM.StreamServer.start_link(
        provider_mod: ReqLLM.Providers.OpenAI,
        model: model,
        high_watermark: 4,
        canonical_stream?: true
      )

    :ok = ReqLLM.StreamServer.set_telemetry_context(server, nil)

    {:ok, upstream} =
      Task.start_link(fn ->
        Enum.each(1..256, fn index ->
          event = {:http_event, {:canonical_chunk, ReqLLM.StreamChunk.text("x")}}
          request = :gen_server.send_request(server, event)

          if index == 132 do
            :timeout = :gen_server.wait_response(request, 0)
            send(observer, :upstream_saturated)
          end

          {:reply, :ok} = :gen_server.receive_response(request, :infinity)
          if index == 133, do: send(observer, :upstream_resumed)
        end)

        ReqLLM.StreamServer.http_event(server, :done)
      end)

    send(observer, {:native_upstream, server, upstream})

    {:ok, metadata} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

    stream =
      Stream.resource(
        fn -> server end,
        fn server ->
          case ReqLLM.StreamServer.next(server) do
            {:ok, chunk} -> {[chunk], server}
            :halt -> {:halt, server}
          end
        end,
        fn _ -> :ok end
      )

    {:ok,
     %ReqLLM.StreamResponse{
       stream: stream,
       metadata_handle: metadata,
       cancel: fn -> ReqLLM.StreamServer.cancel(server) end,
       model: model,
       context: ReqLLM.Context.new(messages)
     }}
  end
end

defmodule Aikido.StreamBackpressureTest do
  use AikidoTest.Case, async: false
  alias Aikido.AiReact.{AttemptBudget, AttemptTiming, StreamDelivery}
  alias Aikido.StreamBackpressureTest.{Agent, Client, NamedAgent}

  test "a blocked consumer bounds pending batches and lazy input at 12 and 12000 chunks", ctx do
    for size <- [12, 12_000] do
      pid = start_server(ctx, Agent)
      observer = self()

      task =
        Task.async(fn ->
          Aikido.AI.ask_sync(pid, "burst",
            model: "offline",
            client: Client,
            llm_opts: [observer: observer, size: size],
            actor: %{observer: observer, gate: true},
            options: %{streaming: true, stream_batch_bytes: 64, stream_batch_ms: 100_000},
            timeout: 30_000
          )
        end)

      assert_receive {:stream_open, producer}, 5_000
      assert_receive {:batch_waiting, ^pid, %{sequence: 1, text: first}}, 5_000
      assert byte_size(first) == min(size, 64)
      assert_receive {:pulled, 1}
      if size >= 64, do: assert_receive({:pulled, 64})

      if size >= 128 do
        assert_receive {:pulled, 65}
        assert_receive {:pulled, 128}
        refute_received {:pulled, 129}
      end

      refute_received {:terminal_processing, _}
      assert {:message_queue_len, pending} = Process.info(pid, :message_queue_len)
      assert pending <= 4
      assert {:messages, messages} = Process.info(pid, :messages)

      refute Enum.any?(
               messages,
               &match?(
                 {:"$gen_call", _, {:signal_with_selector, %{type: "ai.react.stream"}, _}},
                 &1
               )
             )

      IO.puts(
        "STREAM_BACKPRESSURE chunks=#{size} queued_agent_messages=#{pending} pending_bytes=#{min(max(size - 64, 0), 64)}"
      )

      assert Process.alive?(producer)
      send(pid, :release_batch)
      assert {:ok, result} = Task.await(task, 30_000)
      assert result == String.duplicate("x", size)
      sequences = drain_sequences([])
      assert sequences == Enum.to_list(1..ceil(size / 64))
      final_sequence = ceil(size / 64)
      assert_receive {:terminal_processing, ^final_sequence}
      assert {:ok, nil} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.stream_receipt})
    end
  end

  test "agent backpressure reaches the native ReqLLM queue and suspends upstream transport",
       ctx do
    pid = start_server(ctx, Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(pid, "native upstream",
          model: "offline",
          client: Aikido.StreamBackpressureTest.NativeQueueClient,
          llm_opts: [observer: observer],
          actor: %{observer: observer, gate: true},
          options: %{streaming: true, stream_batch_bytes: 64, stream_batch_ms: 100_000}
        )
      end)

    assert_receive {:native_upstream, server, upstream}, 5_000
    assert_receive {:batch_waiting, ^pid, _}, 5_000
    assert_receive :upstream_saturated, 5_000
    native = :sys.get_state(server)
    assert :queue.len(native.queue) == 4
    refute_received :upstream_resumed
    assert Process.alive?(upstream)
    send(pid, :release_batch)
    assert {:ok, result} = Task.await(task)
    assert result == String.duplicate("x", 256)
    assert_receive :upstream_resumed
  end

  test "rejection closes the stream without retrying an ambiguous batch", ctx do
    pid = start_server(ctx, Agent)

    assert {:error, error} =
             Aikido.AI.ask_sync(pid, "reject",
               model: "offline",
               client: Client,
               llm_opts: [observer: self(), size: 100],
               actor: %{observer: self(), reject: true},
               options: %{streaming: true, stream_batch_bytes: 1, model_max_retries: 2}
             )

    assert %Aikido.AiReact.Errors.EffectReceiptLost{} = error
    refute Aikido.Error.retryable?(error)
    assert_receive {:stream_open, _}
    assert_receive :stream_closed
    refute_received {:stream_open, _}
    refute_received {:pulled, 64}
  end

  test "named mounted receipts reject stale, duplicate and out of order writes and never checkpoint",
       ctx do
    pid =
      start_server(ctx, NamedAgent,
        initial_state: %{
          model: %{status: :running, request_id: "current", iteration: 0},
          other: %{status: :running, request_id: "different", iteration: 0}
        }
      )

    first = batch("current", 1)
    assert :ok = deliver(pid, first, timing(), budget())
    assert :ok = deliver(pid, first, timing(), budget())

    assert {:error, %{reason: :stale_batch}} =
             deliver(pid, batch("current", 3), timing(), budget())

    assert {:error, %{reason: :stale_batch}} =
             deliver(pid, batch("old", 2), timing(), budget())

    assert :ok = deliver(pid, batch("current", 2), timing(), budget())

    assert {:ok, {model, other}} =
             Aikido.AgentServer.state(pid, &{:ok, {&1.agent.state.model, &1.agent.state.other}})

    assert model.streaming_text == "xx"
    assert other.streaming_text == ""
    assert model.stream_receipt.sequence == 2
    assert other.stream_receipt == nil
    assert :ok = deliver(pid, batch("current", 1, 1), timing(), budget())

    assert {:error, %{reason: :stale_batch}} =
             deliver(pid, batch("current", 3, 0), timing(), budget())

    assert {:ok, "x"} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.model.streaming_text})
    assert Aikido.AiReact.Slice.externalize(model).stream_receipt == nil
    assert Aikido.AiReact.Slice.reinstate(model).stream_receipt == nil
    {:ok, id} = Aikido.AgentServer.state(pid, &{:ok, &1.id})
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(ctx.aikido), pid)
    restored = start_server(ctx, NamedAgent, id: id)

    assert {:ok, nil} =
             Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.model.stream_receipt})
  end

  test "an expired producer budget dispatches no batch", ctx do
    pid =
      start_server(ctx, Agent, initial_state: %{ai: %{status: :running, request_id: "current"}})

    expired =
      AttemptBudget.new!(
        monotonic_deadline: System.monotonic_time(:millisecond) - 1,
        absolute_deadline_at: System.system_time(:millisecond) + 5_000,
        timeout_ms: 5_000
      )

    assert {:error, %{reason: :deadline}} =
             deliver(pid, batch("current", 1), timing(), expired)

    assert {:ok, ""} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.streaming_text})
  end

  test "the supervising deadline never retries an unacknowledged in-flight batch", ctx do
    clock = start_supervised!({Aikido.AttemptTimingTest.Manual, self()})
    pid = start_server(ctx, Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(pid, "deadline",
          model: "offline",
          client: Client,
          llm_opts: [observer: observer, size: 100],
          actor: %{observer: observer, gate: true},
          context: %{aikido_attempt_timing: {Aikido.AttemptTimingTest.Manual, clock}},
          options: %{
            streaming: true,
            stream_batch_bytes: 64,
            model_timeout_ms: 100,
            progress_timeout_ms: 1_000,
            model_max_retries: 2,
            retry_backoff_ms: 0
          }
        )
      end)

    assert_receive {:stream_open, producer}, 5_000
    assert_receive {:batch_waiting, ^pid, _}, 5_000
    monitor = Process.monitor(producer)
    assert :ok = Aikido.AttemptTimingTest.Manual.advance(clock, 100)
    assert_receive {:DOWN, ^monitor, :process, ^producer, _}, 5_000
    send(pid, :release_batch)
    assert {:error, %Aikido.AiReact.Errors.EffectReceiptLost{} = error} = Task.await(task)
    refute Aikido.Error.retryable?(error)
    assert_receive :stream_closed
    refute_received {:stream_open, _}
    refute_received {:pulled, 129}
  end

  test "call timeout is ambiguous and does not roll back a queued batch", ctx do
    pid =
      start_server(ctx, Agent, initial_state: %{ai: %{status: :running, request_id: "current"}})

    observer = self()

    signal =
      batch("current", 1) |> Aikido.Signal.put_ctx(%{actor: %{observer: observer, gate: true}})

    short =
      AttemptBudget.new!(
        monotonic_deadline: System.monotonic_time(:millisecond) + 100,
        absolute_deadline_at: System.system_time(:millisecond) + 100,
        timeout_ms: 100
      )

    task = Task.async(fn -> deliver(pid, signal, timing(), short) end)
    assert_receive {:batch_waiting, ^pid, _}
    assert {:error, %{reason: :timeout} = error} = Task.await(task)
    refute Aikido.Error.retryable?(error)
    send(pid, :release_batch)
    assert {:ok, "x"} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.streaming_text})
  end

  test "cancellation queued during adoption stops the producer without consuming another batch",
       ctx do
    pid = start_server(ctx, Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(pid, "cancel",
          model: "offline",
          client: Client,
          llm_opts: [observer: observer, size: 100],
          actor: %{observer: observer, gate: true},
          options: %{streaming: true, stream_batch_bytes: 64, model_max_retries: 2}
        )
      end)

    assert_receive {:stream_open, producer}, 5_000
    assert_receive {:batch_waiting, ^pid, _}, 5_000
    monitor = Process.monitor(producer)
    assert :ok = Aikido.AgentServer.cast(pid, Aikido.AiReact.Signals.Cancel.new!(%{}))
    send(pid, :release_batch)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^producer, _}, 5_000
    assert_receive :stream_closed
    refute_received {:stream_open, _}
    refute_received {:terminal_processing, _}
  end

  defp deliver(pid, signal, timing, budget) do
    with {:ok, request} <- StreamDelivery.submit(pid, signal, timing, budget),
         do: StreamDelivery.await(request, timing, budget)
  end

  defp batch(request, sequence, attempt \\ 0) do
    Aikido.AiReact.Signals.Stream.new!(%{
      request_id: request,
      iteration: 1,
      attempt: attempt,
      sequence: sequence,
      text: "x"
    })
  end

  defp timing, do: AttemptTiming.resolve(nil)

  defp budget do
    AttemptBudget.new!(
      monotonic_deadline: System.monotonic_time(:millisecond) + 5_000,
      absolute_deadline_at: System.system_time(:millisecond) + 5_000,
      timeout_ms: 5_000
    )
  end

  defp drain_sequences(sequences) do
    receive do
      {:batch_processed, sequence} -> drain_sequences([sequence | sequences])
    after
      0 -> Enum.reverse(sequences)
    end
  end
end
