defmodule Aikido.ModelRetryTest.HoldTools do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, context) do
    send(context.actor.observer, {:tools_preparing, self()})

    receive do
      :release -> {:ok, input.arguments.options}
    end
  end
end

defmodule Aikido.ModelRetryTest.PrepareProvider do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, context) do
    Aikido.AiReact.Types.ModelRequest.new(
      model: input.arguments.model,
      options: Keyword.put(input.arguments.options, :observer, context.actor.observer)
    )
  end
end

defmodule Aikido.ModelRetryTest.JournalFailure do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    {:context_handoff_failed, reason} = input.context.aikido.agent.state.ai.error

    payload =
      Map.put(
        Aikido.AiReact.ModelAttemptObservation.failure(reason),
        :kind,
        :context_handoff_failed
      )

    thread = input.arguments.state

    with {:ok, updated} <-
           Aikido.Thread.Journal.append(
             thread,
             %{kind: :error, payload: payload},
             input.context.aikido.signal
           ) do
      Aikido.Types.ActionResult.new(changes: Aikido.Thread.Journal.changes(thread, updated))
    end
  end
end

defmodule Aikido.ModelRetryTest.Agent do
  use Aikido.Agent

  agent do
    name "model_retry"
    persistence :permanent
    slice :ai, Aikido.AiReact.Slice
    slice :thread, Aikido.Thread.Slice

    route Aikido.AiReact.Signals.HandoffFailed, Aikido.ModelRetryTest.JournalFailure,
      mount: :thread,
      priority: -20,
      public?: false
  end

  actions do
    action :hold_tools, {:array, :tuple} do
      constraints items: [fields: [key: [type: :atom], value: [type: :term]]]

      argument :options, {:array, :tuple},
        allow_nil?: false,
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      argument :metadata, :map, default: %{}
      run Aikido.ModelRetryTest.HoldTools
    end

    action :prepare_provider, Aikido.AiReact.Types.ModelRequest do
      argument :model, :term, allow_nil?: false

      argument :options, {:array, :tuple},
        allow_nil?: false,
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      run Aikido.ModelRetryTest.PrepareProvider
    end
  end
end

defmodule Aikido.ModelRetryTest.Client do
  def generate_text(_model, _messages, options) do
    send(options[:observer], {:provider_wait, self(), options})

    receive do
      {:respond, response} -> response
    end
  end

  def stream_text(_model, _messages, options) do
    observer = options[:observer]
    send(observer, {:stream_open, self(), options})
    {:ok, metadata} = ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> %{} end)

    stream =
      Stream.resource(
        fn -> nil end,
        fn state ->
          send(observer, {:wire_wait, self()})

          receive do
            {:chunk, chunk} -> {[chunk], state}
          end
        end,
        fn _ -> :ok end
      )

    {:ok,
     %ReqLLM.StreamResponse{
       stream: stream,
       metadata_handle: metadata,
       cancel: fn ->
         send(observer, {:stream_closed, self()})
         :ok
       end,
       model: nil,
       context: ReqLLM.Context.new()
     }}
  end
end

defmodule Aikido.ModelRetryTest do
  use AikidoTest.Case, async: true
  alias Aikido.AiReact.Errors.ProviderRequestFailed
  alias Aikido.AttemptTimingTest.Manual

  setup ctx do
    clock = start_supervised!({Manual, self()})
    actor = %{id: unique_id("model-owner"), observer: self()}
    owner = start_server(ctx, Aikido.ModelRetryTest.Agent, initialization_options: [actor: actor])
    %{clock: clock, owner: owner, actor: actor}
  end

  test "tool preparation uses the same supplied clock before the first model attempt", ctx do
    deadline = Manual.system_ms(ctx.clock) + 100

    {:ok, _} =
      ask(ctx, deadline,
        options: %{
          model_timeout_ms: 50,
          tool_preparation: {Aikido.ModelRetryTest.Agent, :hold_tools}
        }
      )

    assert_receive {:tools_preparing, worker}, 5_000
    monitor = Process.monitor(worker)
    assert_receive {:armed, _, _, 50}, 5_000
    :ok = Manual.advance(ctx.clock, 50)
    state = await_state(ctx.owner, &(&1.ai.status == :failed))
    assert state.ai.error == :timeout
    assert state.ai.model_attempts == []
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
    refute_receive {:provider_wait, _, _}
  end

  test "silent nonstreaming handoff retries spend one deadline and persist a typed journal receipt",
       ctx do
    assert %{status: :processed} =
             Aikido.ModelRetryTest.Agent
             |> Ash.ActionInput.for_action(
               :replace_context,
               %{
                 agent: ctx.owner,
                 messages: [ReqLLM.Context.user(String.duplicate("evidence ", 3_000))]
               },
               actor: ctx.actor
             )
             |> Ash.run_action!()

    deadline = Manual.system_ms(ctx.clock) + 150

    {:ok, _} =
      ask(ctx, deadline, options: %{context_max_tokens: 5_000, handoff_buffer_tokens: 1_000})

    assert_receive {:provider_wait, first, first_options}, 5_000
    assert first_options[:total_timeout] == 100
    assert first_options[:receive_timeout] == 100
    assert first_options[:req_http_options][:finch][:pool_timeout] == 100
    first_monitor = Process.monitor(first)
    await_attempt(ctx.owner, &(&1.mode == :handoff && &1.phase == :started))
    :ok = Manual.advance(ctx.clock, 100)
    backoff = await_attempt(ctx.owner, &(&1.phase == :backoff))
    assert backoff.delay_ms == 20
    assert backoff.timeout_phase == :attempt
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :killed}, 5_000

    :ok = Manual.advance(ctx.clock, 120)
    assert_receive {:provider_wait, second, second_options}, 5_000
    assert second != first
    assert second_options[:total_timeout] == 30
    assert second_options[:receive_timeout] == 30
    assert second_options[:req_http_options][:finch][:pool_timeout] == 30
    :ok = Manual.advance(ctx.clock, 150)

    state = await_state(ctx.owner, &(&1.ai.status == :failed && terminal?(&1.ai)))

    assert {:context_handoff_failed, %ProviderRequestFailed{timeout_phase: :deadline}} =
             state.ai.error

    assert state.ai.deadline_at == deadline
    refute Keyword.has_key?(state.ai.llm_opts, :observer)
    assert state.ai.handoff_pending == nil

    assert [%{kind: :error, payload: %{kind: :context_handoff_failed, timeout_phase: :deadline}}] =
             state.thread.entries

    assert Enum.all?(state.ai.model_attempts, &(&1.deadline_at == deadline))
    refute_receive {:provider_wait, _, _}

    pool = Aikido.durable_supervisor_name(ctx.aikido)
    {:ok, id} = Aikido.AgentServer.state(ctx.owner, &{:ok, &1.id})
    assert :ok = Aikido.Durable.stop(pool, ctx.owner, scope: %{actor: ctx.actor})
    restored = start_server(ctx, Aikido.ModelRetryTest.Agent, id: id)

    assert {:ok, receipt} =
             Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.thread.entries})

    assert receipt == state.thread.entries
  end

  test "opened zero-chunk stream times out, cleans up and backs off without inventing HTTP status",
       ctx do
    deadline = Manual.system_ms(ctx.clock) + 100
    {:ok, _} = ask(ctx, deadline, options: %{streaming: true, progress_timeout_ms: 40})
    assert_receive {:stream_open, first, _options}, 5_000
    assert_receive {:wire_wait, ^first}, 5_000
    await_attempt(ctx.owner, &Map.get(&1, :opened, false))
    :ok = Manual.advance(ctx.clock, 40)
    attempt = await_attempt(ctx.owner, &(&1.phase == :backoff))
    assert attempt.opened
    assert attempt.wire_chunks == 0
    assert attempt.qualifying_chunks == 0
    refute Map.has_key?(attempt, :status)
    refute Map.has_key?(attempt, :first_chunk_at)
    assert attempt.timeout_phase == :stream_idle
    assert is_integer(attempt.cleanup_at)
    assert_receive {:stream_closed, _}, 5_000
    :ok = Manual.advance(ctx.clock, 60)
    assert_receive {:stream_open, second, options}, 5_000
    assert options[:total_timeout] == 40
    assert_receive {:wire_wait, ^second}, 5_000
    :ok = Manual.advance(ctx.clock, 100)
    state = await_state(ctx.owner, &(&1.ai.status == :failed && terminal?(&1.ai)))
    assert %ProviderRequestFailed{timeout_phase: :deadline} = state.ai.error
  end

  test "qualifying unrendered chunks cannot extend the inherited absolute deadline", ctx do
    deadline = Manual.system_ms(ctx.clock) + 100

    {:ok, _} =
      ask(ctx, deadline,
        options: %{
          streaming: true,
          model_timeout_ms: 200,
          progress_timeout_ms: 40,
          model_max_retries: 0
        }
      )

    assert_receive {:stream_open, worker, _}, 5_000
    assert_receive {:wire_wait, ^worker}, 5_000
    assert_receive {:armed, caller, _, 40}, 5_000

    for {time, count} <- [{30, 1}, {60, 2}, {90, 3}] do
      :ok = Manual.advance(ctx.clock, time)

      send(
        worker,
        {:chunk, %ReqLLM.StreamChunk{type: :content_part, content_part: %{kind: :opaque}}}
      )

      assert_receive {:wire_wait, ^worker}, 5_000
      expected = min(time + 40, 100)
      assert_receive {:armed, ^caller, _, ^expected}, 5_000
      attempt = await_attempt(ctx.owner, &(Map.get(&1, :wire_chunks) == count))
      assert attempt.qualifying_chunks == count
      assert attempt.nonqualifying_chunks == 0
      assert attempt.rendered_chunks == 0
    end

    :ok = Manual.advance(ctx.clock, 100)
    state = await_state(ctx.owner, &(&1.ai.status == :failed && terminal?(&1.ai)))
    assert %ProviderRequestFailed{timeout_phase: :deadline} = state.ai.error
    assert state.ai.streaming_text == ""
    assert state.ai.streaming_thinking == ""
    [attempt] = state.ai.model_attempts
    assert attempt.wire_chunks == 3
    assert attempt.qualifying_chunks == 3
    assert attempt.rendered_chunks == 0
    assert attempt.outcome == :failed
    assert is_integer(attempt.first_chunk_at)
    assert is_integer(attempt.cleanup_at)
    assert is_integer(attempt.ended_at)
    assert is_integer(attempt.delivered_at)
  end

  test "same-signature failures open a typed circuit inside the existing retry budget", ctx do
    deadline = Manual.system_ms(ctx.clock) + 300

    {:ok, _} =
      ask(ctx, deadline, options: %{provider_failure_threshold: 2, provider_backoff_ms: 50})

    assert_receive {:provider_wait, first, _}, 5_000
    error = ReqLLM.Error.API.Stream.exception(reason: "synthetic private provider text")
    send(first, {:respond, {:error, error}})
    await_attempt(ctx.owner, &(&1.phase == :backoff))
    :ok = Manual.advance(ctx.clock, 20)
    assert_receive {:provider_wait, second, _}, 5_000
    send(second, {:respond, {:error, error}})
    backoff = await_attempt(ctx.owner, &(&1.phase == :provider_backoff))
    assert backoff.delay_ms == 50
    assert backoff.cause_type == ReqLLM.Error.API.Stream
    refute Map.has_key?(backoff, :status)
    refute inspect(backoff) =~ "synthetic private provider text"
    :ok = Manual.advance(ctx.clock, 69)
    refute_receive {:provider_wait, _, _}
    :ok = Manual.advance(ctx.clock, 70)
    assert_receive {:provider_wait, third, _}, 5_000

    send(
      third,
      {:respond, {:ok, Aikido.AI.Test.ResponseFixtures.final_answer_response("recovered")}}
    )

    state = await_state(ctx.owner, &(&1.ai.status == :completed && terminal?(&1.ai)))
    assert state.ai.result == "recovered"
    assert length(state.ai.model_attempts) == 3
    assert hd(state.ai.model_attempts).outcome == :completed
  end

  test "circuit cancellation interrupts the wait, and lifecycle telemetry contains safe typed facts",
       ctx do
    handler = {__MODULE__, make_ref()}

    events =
      for phase <- [:started, :ended, :cleanup, :provider_backoff, :terminal],
          do: [:aikido, :ai, :model_attempt, phase]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.attempt_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    deadline = Manual.system_ms(ctx.clock) + 300

    {:ok, _} =
      ask(ctx, deadline, options: %{provider_failure_threshold: 1, provider_backoff_ms: 250})

    assert_receive {:provider_wait, first, _}, 5_000

    send(
      first,
      {:respond,
       {:error,
        ReqLLM.Error.API.Response.exception(
          status: 429,
          response_body: %{secret: "SYNTHETIC-PRIVATE-BODY"}
        )}}
    )

    backoff = await_attempt(ctx.owner, &(&1.phase == :provider_backoff))
    assert backoff.status == 429
    assert backoff.delay_ms == 250
    assert backoff.cause_type == ReqLLM.Error.API.Response

    assert_receive {:attempt_event, [:aikido, :ai, :model_attempt, :provider_backoff],
                    %{system_time: _}, facts},
                   5_000

    assert facts.phase == :provider_backoff
    refute inspect(facts) =~ "SYNTHETIC-PRIVATE-BODY"

    assert :ok = Aikido.AI.cancel(ctx.owner, nil, actor: ctx.actor)
    state = await_state(ctx.owner, &(&1.ai.status == :failed && terminal?(&1.ai)))
    assert state.ai.error == :cancelled
    assert hd(state.ai.model_attempts).terminal_outcome == :cancelled
    :ok = Manual.advance(ctx.clock, 300)
    refute_receive {:provider_wait, _, _}
  end

  @doc false
  def attempt_event(event, measurements, metadata, observer),
    do: send(observer, {:attempt_event, event, measurements, metadata})

  defp ask(ctx, deadline, overrides) do
    options =
      Map.merge(
        %{
          model_preparation: {Aikido.ModelRetryTest.Agent, :prepare_provider},
          model_timeout_ms: 100,
          model_max_retries: 2,
          retry_backoff_ms: 20
        },
        Keyword.get(overrides, :options, %{})
      )

    Aikido.AI.ask(ctx.owner, "continue",
      model: "offline",
      actor: ctx.actor,
      client: Aikido.ModelRetryTest.Client,
      tools: [],
      llm_opts: [],
      options: options,
      metadata: %{aikido_deadline_at: deadline},
      context: %{aikido_attempt_timing: {Manual, ctx.clock}}
    )
  end

  defp await_attempt(owner, predicate) do
    await_state_value(
      owner,
      fn runtime -> Enum.find(runtime.agent.state.ai.model_attempts, predicate) end,
      timeout: 5_000
    )
  end

  defp await_state(owner, predicate) do
    await_state_value(
      owner,
      fn runtime -> if predicate.(runtime.agent.state), do: runtime.agent.state end,
      timeout: 5_000
    )
  end

  defp terminal?(ai), do: Enum.any?(ai.model_attempts, &(&1.phase == :terminal))
end
