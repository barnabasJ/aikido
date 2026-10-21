defmodule Aikido.ContextHandoffTest.Agent do
  use Aikido.Agent

  agent do
    name "context_handoff"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.ContextHandoffTest.Client do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:request, self(), messages, opts[:tools]})

    receive do
      {:answer, result} -> result
    end
  end
end

defmodule Aikido.ContextHandoffTest do
  use AikidoTest.Case, async: false
  use Mimic
  alias Aikido.ContextHandoffTest.{Agent, Client}

  setup :set_mimic_global
  setup :verify_on_exit!

  test "a model-written document replaces context, preserves queued messages, and reuses prepared tools",
       ctx do
    expect(AshAi, :build_tools_and_registry, fn opts ->
      Mimic.call_original(AshAi, :build_tools_and_registry, [opts])
    end)

    pid = start_server(ctx, Agent)
    observer = self()
    original = String.duplicate("evidence ", 1_400)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, original, options(observer)) end)
    assert_receive {:request, writer, messages, []}, 5_000
    assert text(Enum.at(messages, 1)) == String.trim(original)
    assert text(List.last(messages)) =~ "ONLY thing your successor receives"
    assert {:ok, %{status: :running, handoff_pending: 1}} = ai(pid)
    assert {:ok, :queued} = Aikido.AI.queue_message(pid, "new instruction")

    document =
      "Mission: inspect evidence. Decision: use native tools. Next action: verify the conclusion."

    send(
      writer,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          usage: %{input_tokens: 4_400, output_tokens: 50},
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant(document, tool_calls: []),
          finish_reason: :stop
        }}}
    )

    assert_receive {:request, successor, fresh, [%ReqLLM.Tool{name: "test_add"}]}, 5_000
    assert Enum.map(fresh, & &1.role) == [:system, :user, :user]
    assert text(hd(fresh)) == "Keep the standing procedure."
    assert text(Enum.at(fresh, 1)) =~ document
    assert text(List.last(fresh)) == "new instruction"
    refute Enum.any?(fresh, &(text(&1) == String.trim(original)))

    assert {:ok, %{last_handoff: %{document: ^document}, handoff_pending: nil} = resumed} =
             ai(pid)

    assert resumed.estimated_tokens ==
             Aikido.AiReact.Conversation.estimate_tokens(resumed.context)

    assert resumed.last_input_tokens == nil

    send(
      successor,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          usage: %{input_tokens: 100, output_tokens: 10},
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("done", tool_calls: []),
          finish_reason: :stop
        }}}
    )

    assert {:ok, "done"} = Task.await(task)
    assert {:ok, %{usage: %{input_tokens: 4_500, output_tokens: 60}}} = ai(pid)
  end

  test "handoff waits until every tool result is recorded", ctx do
    pid = start_server(ctx, Agent)
    observer = self()

    opts =
      options(observer)
      |> Keyword.put(:tools, [:test_wait])
      |> Keyword.put(:tool_context, %{context: %{observer: observer}})

    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", opts) end)
    assert_receive {:request, model, _, [_]}, 5_000
    calls = for id <- ["one", "two"], do: %{id: id, name: "test_wait", arguments: %{}}

    send(
      model,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          usage: %{input_tokens: 4_400},
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("", tool_calls: calls),
          finish_reason: :tool_calls
        }}}
    )

    assert_receive {:tool_running, first}, 5_000
    assert_receive {:tool_running, second}, 5_000

    {:ok, result} =
      Aikido.AgentServer.subscribe(
        pid,
        "ai.react.tool.completed",
        fn runtime ->
          if length(runtime.agent.state.ai.tool_results_received) == 1,
            do: {:ok, :one_result},
            else: :skip
        end,
        once: true
      )

    send(first, :continue)
    assert_receive {:aikido_subscription, ^result, %{result: {:ok, :one_result}}}, 5_000
    assert {:ok, %{handoff_pending: nil}} = ai(pid)
    refute_received {:request, _, _, _}
    send(second, :continue)
    assert_receive {:request, writer, history, []}, 5_000
    assert Enum.count(history, &(&1.role == :tool)) == 2

    send(
      writer,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message:
            ReqLLM.Context.assistant("Both workers finished. Next action: report the result.",
              tool_calls: []
            ),
          finish_reason: :stop
        }}}
    )

    assert_receive {:request, successor, _, [_]}, 5_000

    send(
      successor,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("done", tool_calls: []),
          finish_reason: :stop
        }}}
    )

    assert {:ok, "done"} = Task.await(task)
  end

  test "failed or unusable handoffs preserve the original history instead of trimming", ctx do
    for {result, reason} <- [
          {{:error, :provider_unavailable}, :provider_unavailable},
          {{:ok,
            %ReqLLM.Response{
              id: "scripted",
              model: "offline",
              context: ReqLLM.Context.new(),
              message: ReqLLM.Context.assistant("   ", tool_calls: []),
              finish_reason: :stop
            }}, :empty_or_invalid_document},
          {{:ok,
            %ReqLLM.Response{
              id: "scripted",
              model: "offline",
              context: ReqLLM.Context.new(),
              message: ReqLLM.Context.assistant("partial", tool_calls: []),
              finish_reason: :length
            }}, :truncated_document},
          {{:ok,
            %ReqLLM.Response{
              id: "scripted",
              model: "offline",
              context: ReqLLM.Context.new(),
              message: ReqLLM.Context.assistant("not a document", tool_calls: []),
              finish_reason: :tool_calls
            }}, :empty_or_invalid_document}
        ] do
      pid = start_server(ctx, Agent)
      observer = self()
      original = String.duplicate("evidence ", 1_400)
      task = Task.async(fn -> Aikido.AI.ask_sync(pid, original, options(observer)) end)
      assert_receive {:request, writer, _, []}, 5_000
      assert {:ok, before} = ai(pid)
      send(writer, {:answer, result})
      assert {:error, {:context_handoff_failed, ^reason}} = Task.await(task)
      assert {:ok, after_failure} = ai(pid)
      assert after_failure.context == before.context
      assert text(List.last(after_failure.context.messages)) == String.trim(original)
      refute_received {:request, _, _, _}
    end
  end

  test "cancelling a handoff stops the request and ignores its late result", ctx do
    pid = start_server(ctx, Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), options(observer))
      end)

    assert_receive {:request, writer, _, []}, 5_000
    monitor = Process.monitor(writer)
    assert {:ok, %{request_id: id, handoff_pending: handoff_id}} = ai(pid)
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^writer, _}, 5_000

    late =
      Aikido.Signal.new!("ai.react.context_handoff.completed", %{
        request_id: id,
        handoff_id: handoff_id,
        turn: %ReqLLM.Response{
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("late", tool_calls: []),
          finish_reason: :stop
        }
      })

    assert {:ok, :failed} = Aikido.AgentServer.call(pid, late, &{:ok, &1.agent.state.ai.status})
    refute_received {:request, _, _, _}
  end

  defp ai(pid), do: Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
  defp text(message), do: Enum.map_join(message.content, &(&1.text || ""))

  defp options(observer),
    do: [
      model: "offline",
      client: Client,
      tools: [:test_add],
      system_prompt: "Keep the standing procedure.",
      llm_opts: [observer: observer],
      timeout: 10_000,
      options: %{context_max_tokens: 5_000, handoff_buffer_tokens: 1_000}
    ]
end
