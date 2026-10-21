defmodule Aikido.AICancellationHooksTest.Agent do
  use Aikido.Agent

  agent do
    name "ai_cancellation_hooks"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.AICancellationHooksTest.Client do
  def stream_text(_, messages, opts) do
    observer = opts[:observer]

    {:ok, metadata} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

    stream =
      Stream.map([ReqLLM.StreamChunk.text("answer")], fn chunk ->
        send(observer, {:model_started, self()})

        receive do
          :finish -> chunk
        end
      end)

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

  def request(_, %{event: %{type: event, metadata: %{observer: observer}}}) do
    send(observer, {:hook_waiting, event, self()})

    receive do
      :release -> {:ok, %{}}
    end
  end
end

defmodule Aikido.AICancellationHooksTest do
  use AikidoTest.Case, async: true
  alias Aikido.AICancellationHooksTest.{Agent, Client}

  test "cancellation stops and cleans up model work before its terminal hook finishes", ctx do
    pid = start_server(ctx, Agent)

    assert {:ok, request_id} =
             Aikido.AI.ask(pid, "run",
               model: "offline",
               client: Client,
               metadata: %{observer: self()},
               llm_opts: [observer: self()],
               options: %{streaming: true},
               hooks:
                 for event <- [:before_model, :run_cancelled] do
                   %{
                     name: to_string(event),
                     event: event,
                     script: ~s|aikido.request("wait", {})|,
                     request: &Client.request/2
                   }
                 end
             )

    assert_receive {:hook_waiting, :before_model, before_model}, 5_000
    assert {:ok, :setup} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.status})
    send(before_model, :release)
    assert_receive {:model_started, model}, 5_000
    monitor = Process.monitor(model)

    {:ok, terminal} =
      Aikido.AgentServer.subscribe(
        pid,
        "ai.react.**",
        fn runtime ->
          ai = runtime.agent.state.ai
          if ai.status == :failed, do: {:ok, ai.error}, else: :skip
        end,
        once: true
      )

    assert :ok = Aikido.AI.cancel(pid, request_id)
    assert_receive {:hook_waiting, :run_cancelled, cancelled_hook}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^model, _}, 5_000
    assert_receive :stream_closed, 5_000

    assert {:ok, %{status: :running, hook_terminal: :failed, error: :cancelled}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})

    assert Process.alive?(cancelled_hook)
    refute_received {:aikido_subscription, ^terminal, _}
    send(cancelled_hook, :release)
    assert_receive {:aikido_subscription, ^terminal, %{result: {:ok, :cancelled}}}, 5_000
  end
end
