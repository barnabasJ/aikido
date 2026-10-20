defmodule Aikido.ReactFeaturesTest.Agent do
  use Aikido.Agent

  agent do
    name "react_features"
    slice :ai, Aikido.Slices.AiReact
  end
end

defmodule Aikido.ReactFeaturesTest.Client do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model, self(), messages})

    receive do
      {:answer, value} -> value
    end
  end

  def stream_text(_, messages, opts) do
    observer = opts[:observer]
    send(observer, {:stream, self()})

    {:ok, metadata} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{input_tokens: 5, output_tokens: 2}, finish_reason: :stop}
      end)

    stream =
      Stream.map(
        [
          ReqLLM.StreamChunk.text("hello "),
          ReqLLM.StreamChunk.thinking("reason"),
          ReqLLM.StreamChunk.text("world")
        ],
        fn chunk ->
          if chunk.text == "world",
            do:
              (receive do
                 :finish_stream -> :ok
               end)

          chunk
        end
      )

    {:ok,
     %ReqLLM.StreamResponse{
       stream: stream,
       metadata_handle: metadata,
       cancel: fn ->
         send(observer, :stream_closed)
         :ok
       end,
       model: %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"},
       context: ReqLLM.Context.new(messages)
     }}
  end
end

defmodule Aikido.ReactFeaturesTest do
  use AikidoTest.Case, async: false
  alias Aikido.ReactFeaturesTest.{Agent, Client}
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  defp options(extra \\ []),
    do:
      Keyword.merge(
        [model: "offline", client: Client, llm_opts: [observer: self()], timeout: 5_000],
        extra
      )

  test "successive requests retain history and messages queued in flight get their own turn",
       ctx do
    pid = start_server(ctx, Agent)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "first", ctx.options) end)
    assert_receive {:model, worker, _}, 2_000
    assert {:ok, :queued} = Aikido.AI.queue_message(pid, "queued")
    send(worker, {:answer, {:ok, Responses.final_answer_response("one")}})
    assert_receive {:model, second, messages}, 2_000
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]
    send(second, {:answer, {:ok, Responses.final_answer_response("two")}})
    assert {:ok, "two"} = Task.await(task)
    opts = options()
    next = Task.async(fn -> Aikido.AI.ask_sync(pid, "third", opts) end)
    assert_receive {:model, third, messages}, 2_000
    assert length(messages) == 5
    send(third, {:answer, {:ok, Responses.final_answer_response("three")}})
    assert {:ok, "three"} = Task.await(next)
    assert {:ok, ai} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
    assert ai.estimated_tokens == Aikido.Slices.AiReact.Context.estimate_tokens(ai.context)
  end

  setup do
    %{options: options()}
  end

  test "cancellation kills an active model attempt and a later request still works", ctx do
    pid = start_server(ctx, Agent)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "cancel", ctx.options) end)
    assert_receive {:model, worker, _}, 2_000
    monitor = Process.monitor(worker)
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    next = Task.async(fn -> Aikido.AI.ask_sync(pid, "next", ctx.options) end)
    assert_receive {:model, worker, _}, 2_000
    send(worker, {:answer, {:ok, Responses.final_answer_response("ok")}})
    assert {:ok, "ok"} = Task.await(next)
  end

  test "model deadlines return a terminal error and retries are explicitly configurable", ctx do
    pid = start_server(ctx, Agent)
    opts = options(options: %{model_timeout_ms: 200})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "timeout", opts) end)
    assert_receive {:model, worker, _}, 2_000
    monitor = Process.monitor(worker)
    assert {:error, :timeout} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000

    opts = options(options: %{model_max_retries: 1, retry_backoff_ms: 0})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "retry", opts) end)
    assert_receive {:model, first, _}, 2_000
    send(first, {:answer, {:error, :timeout}})
    assert_receive {:model, second, _}, 2_000
    refute first == second
    send(second, {:answer, {:ok, Responses.final_answer_response("recovered")}})
    assert {:ok, "recovered"} = Task.await(task)
  end

  test "streamed text and thinking arrive before the final answer and usage is recorded", ctx do
    pid = start_server(ctx, Agent)

    {:ok, progress} =
      Aikido.AgentServer.subscribe(
        pid,
        "ai.react.stream",
        fn runtime ->
          {:ok,
           Map.take(runtime.agent.state.ai, [
             :streaming_text,
             :streaming_thinking,
             :iteration,
             :status
           ])}
        end,
        once: true
      )

    opts = options(options: %{streaming: true, stream_batch_bytes: 1})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "stream", opts) end)
    assert_receive {:stream, worker}, 2_000

    assert_receive {:aikido_subscription, ^progress, %{result: {:ok, partial}}},
                   2_000,
                   inspect(
                     {Aikido.AgentServer.state(
                        pid,
                        &{:ok,
                         Map.take(&1.agent.state.ai, [:status, :streaming_text, :error, :options])}
                      ), Process.info(worker, :current_stacktrace)}
                   )

    assert partial.streaming_text == "hello "
    send(worker, :finish_stream)
    assert {:ok, "hello world"} = Task.await(task)

    assert {:ok, %{input_tokens: 5}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.usage})
  end

  test "a timed-out tool returns conversational error data and its task is stopped", ctx do
    opts =
      options(
        tools: [:test_wait],
        tool_context: %{context: %{observer: self()}},
        options: %{tool_timeout_ms: 200}
      )

    pid = start_server(ctx, Agent)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "use tool", opts) end)
    assert_receive {:model, worker, _}, 2_000

    turn =
      %ReqLLM.Response{
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message:
          ReqLLM.Context.assistant("",
            tool_calls: [%{id: "one", name: "test_wait", arguments: %{}}]
          ),
        finish_reason: :tool_calls
      }

    send(worker, {:answer, {:ok, turn}})
    assert_receive {:tool_running, tool_worker}, 2_000
    monitor = Process.monitor(tool_worker)
    assert_receive {:DOWN, ^monitor, :process, ^tool_worker, _}, 2_000
    assert_receive {:model, next, messages}, 2_000
    result = Enum.find(messages, &(&1.role == :tool))
    assert Enum.map_join(result.content, & &1.text) =~ "timeout"
    send(next, {:answer, {:ok, Responses.final_answer_response("tool failed safely")}})
    assert {:ok, "tool failed safely"} = Task.await(task)
  end

  test "queued messages cannot change the actor or tenant of an active run", ctx do
    pid = start_server(ctx, Agent)
    opts = options(actor: %{id: "alice"}, tenant: "a")
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "first", opts) end)
    assert_receive {:model, worker, _}, 2_000

    assert {:error, _} =
             Aikido.AI.queue_message(pid, "other caller", actor: %{id: "bob"}, tenant: "b")

    assert {:ok, :queued} =
             Aikido.AI.queue_message(pid, "same caller", actor: %{id: "alice"}, tenant: "a")

    send(worker, {:answer, {:ok, Responses.final_answer_response("first")}})
    assert_receive {:model, next, messages}, 2_000
    assert Enum.map_join(List.last(messages).content, & &1.text) == "same caller"
    send(next, {:answer, {:ok, Responses.final_answer_response("second")}})
    assert {:ok, "second"} = Task.await(task)
  end

  test "replace_context validates replacement history and refuses to replace an active run",
       ctx do
    pid = start_server(ctx, Agent)

    replace_context = fn messages ->
      Aikido.AgentServer.call(
        pid,
        Aikido.Signal.new!("ai.react.replace_context", %{messages: messages}),
        &{:ok, &1.agent.state.ai}
      )
    end

    assert {:ok, replaced} = replace_context.([ReqLLM.Context.user("previous summary")])

    assert replaced.estimated_tokens ==
             Aikido.Slices.AiReact.Context.estimate_tokens(replaced.context)

    assert replaced.last_input_tokens == nil
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "continue", ctx.options) end)
    assert_receive {:model, worker, messages}, 2_000
    assert length(messages) == 2
    assert {:error, _} = replace_context.([])
    send(worker, {:answer, {:ok, Responses.final_answer_response("continued")}})
    assert {:ok, "continued"} = Task.await(task)
  end

  test "busy deliveries retain structured correlation metadata", ctx do
    pid = start_server(ctx, Agent)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "first", ctx.options) end)
    assert_receive {:model, worker, _}, 2_000

    signal =
      Aikido.Signal.new!("ai.react.deliver", %{
        text: "worker result",
        request_id: "delivery",
        metadata: %{step_id: "application"}
      })

    assert {:ok, ai} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state.ai})

    assert [%{request_id: "delivery", metadata: %{step_id: "application"}}] =
             ai.run_metadata.deliveries

    send(worker, {:answer, {:ok, Responses.final_answer_response("first")}})
    assert_receive {:model, next, _}, 2_000
    send(next, {:answer, {:ok, Responses.final_answer_response("finished")}})
    assert {:ok, "finished"} = Task.await(task)
  end

  test "restoring a run clears continuations and closes unfinished tool calls", ctx do
    pid = start_server(ctx, Agent)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "first", ctx.options) end)
    assert_receive {:model, worker, _}, 2_000
    {:ok, ai} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})

    context =
      ReqLLM.Context.append(
        ai.context,
        ReqLLM.Context.assistant("call",
          tool_calls: [%{id: "pending", name: "tool", arguments: %{}}]
        )
      )

    restored =
      ai
      |> Map.put(:context, context)
      |> Map.put(:run_scope, %{actor: %{id: "alice"}})
      |> Map.put(:estimated_tokens, 999_999)
      |> Map.put(:last_input_tokens, 888_888)
      |> Aikido.Slices.AiReact.externalize()
      |> Aikido.Slices.AiReact.reinstate()

    assert restored.status == :failed
    assert restored.error == :interrupted

    assert restored.estimated_tokens ==
             Aikido.Slices.AiReact.Context.estimate_tokens(restored.context)

    assert restored.last_input_tokens == nil
    assert restored.run_scope == %{}
    assert restored.hooks_pending == %{}
    assert List.last(restored.context.messages).role == :tool
    send(worker, {:answer, {:ok, Responses.final_answer_response("done")}})
    assert {:ok, "done"} = Task.await(task)
  end

  test "interruption repair retains system instructions and pairs tool calls" do
    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system("keep these instructions"),
        ReqLLM.Context.user(String.duplicate("old ", 2_000)),
        ReqLLM.Context.assistant("call", tool_calls: [%{id: "one", name: "tool", arguments: %{}}])
      ])

    repaired = Aikido.Slices.AiReact.Context.close_tool_calls(context)
    assert List.last(repaired.messages).role == :tool

    assert hd(repaired.messages).role == :system
    assert Enum.map(Enum.take(repaired.messages, -2), & &1.role) == [:assistant, :tool]
  end
end
