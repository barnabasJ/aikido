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
    original = String.duplicate("retained evidence ", 700)

    assert %{status: :processed} =
             Agent
             |> Ash.ActionInput.for_action(:replace_context, %{
               agent: pid,
               messages: [ReqLLM.Context.user(original), ReqLLM.Context.assistant("Old finding")]
             })
             |> Ash.run_action!()

    query = "Continue from the retained finding"
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, query, options(observer)) end)
    assert_receive {:request, writer, messages, []}, 5_000
    assert text(Enum.at(messages, 1)) == original
    assert Enum.count(messages, &(text(&1) == query)) == 1
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
    assert Enum.map(fresh, & &1.role) == [:system, :user, :user, :user]
    assert text(hd(fresh)) == "Keep the standing procedure."
    assert text(Enum.at(fresh, 1)) =~ document
    assert text(Enum.at(fresh, 2)) == query
    assert Enum.count(fresh, &(text(&1) == query)) == 1
    assert text(List.last(fresh)) == "new instruction"
    assert Enum.count(fresh, &(text(&1) == "new instruction")) == 1
    refute Enum.any?(fresh, &(text(&1) == original))

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

  test "queued input before a later tool boundary survives the writer once", ctx do
    pid = start_server(ctx, Agent)
    observer = self()
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "start", options(observer)) end)
    assert_receive {:request, first, _, [_ | _]}, 5_000

    tool_turn = fn id, input_tokens ->
      %ReqLLM.Response{
        usage: %{input_tokens: input_tokens},
        id: id,
        model: "offline",
        context: ReqLLM.Context.new(),
        message:
          ReqLLM.Context.assistant("",
            tool_calls: [ReqLLM.ToolCall.new(id, "test_add", ~s({"a":1,"b":2}))]
          ),
        finish_reason: :tool_calls
      }
    end

    send(first, {:answer, {:ok, tool_turn.("first", 1_000)}})
    assert_receive {:request, later, _messages, [_ | _]}, 5_000
    assert {:ok, :queued} = Aikido.AI.queue_message(pid, "later instruction")
    send(later, {:answer, {:ok, tool_turn.("second", 4_400)}})
    assert_receive {:request, writer, writer_messages, []}, 5_000
    assert Enum.count(writer_messages, &(text(&1) == "later instruction")) == 1

    send(
      writer,
      {:answer, {:ok, Aikido.AI.Test.ResponseFixtures.final_answer_response("Handoff document")}}
    )

    assert_receive {:request, successor, fresh, [_ | _]}, 5_000
    assert Enum.count(fresh, &(text(&1) == "later instruction")) == 1

    assert Enum.find_index(fresh, &(text(&1) =~ "Handoff document")) <
             Enum.find_index(fresh, &(text(&1) == "later instruction"))

    send(
      successor,
      {:answer, {:ok, Aikido.AI.Test.ResponseFixtures.final_answer_response("done")}}
    )

    assert {:ok, "done"} = Task.await(task)
  end

  test "public ask_sync fails on unfinished executable calls at its last turn", ctx do
    pid = start_server(ctx, Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(
          pid,
          "bounded work",
          options(observer)
          |> Keyword.put(:max_iterations, 1)
          |> Keyword.put(:options, %{handoff: false})
        )
      end)

    assert_receive {:request, model, _messages, [_ | _]}, 5_000
    calls = [ReqLLM.ToolCall.new("limit-call", "test_add", ~s({"a":1,"b":2}))]

    send(
      model,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          usage: %{input_tokens: 11, output_tokens: 7},
          id: "last-turn",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("unfinished", tool_calls: calls),
          finish_reason: :tool_calls
        }}}
    )

    assert {:error, :max_iterations} = Task.await(task)
    assert {:ok, %{status: :failed, error: :max_iterations, iteration: 1} = state} = ai(pid)
    assert state.usage.input_tokens == 11
    assert state.usage.output_tokens == 7
    assert List.last(state.context.messages).tool_calls == calls
    assert state.pending_tool_calls == []
    refute_received {:request, _, _, _}
  end

  test "public ask_sync accepts a final answer on its last allowed turn", ctx do
    pid = start_server(ctx, Agent)
    observer = self()

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(
          pid,
          "one final turn",
          options(observer) |> Keyword.put(:max_iterations, 1)
        )
      end)

    assert_receive {:request, model, _messages, _tools}, 5_000

    send(
      model,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "final-turn",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("finished", tool_calls: []),
          finish_reason: :stop
        }}}
    )

    assert {:ok, "finished"} = Task.await(task)
    assert {:ok, %{status: :completed, iteration: 1}} = ai(pid)
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

  test "summary regeneration preserves history, usage and fresh correlation", ctx do
    pid = start_server(ctx, Agent)
    opts = regeneration_options(self())

    task =
      Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

    assert_receive {:request, first, _, []}, 5_000
    assert {:ok, original} = ai(pid)
    send(first, {:answer, {:ok, summary_response("   ")}})
    assert_receive {:request, retry, messages, []}, 5_000
    assert text(List.last(messages)) =~ "previous summary was empty"
    assert {:ok, retried} = ai(pid)
    assert retried.context == original.context
    assert retried.handoff_regenerations == 1
    assert retried.handoff_pending != original.handoff_pending
    assert retried.usage.input_tokens == 20

    late =
      Aikido.AiReact.Signals.HandoffCompleted.new!(%{
        request_id: original.request_id,
        handoff_id: original.handoff_pending,
        turn: summary_response("stale summary")
      })

    assert {:ok, unchanged} = Aikido.AgentServer.call(pid, late, &{:ok, &1.agent.state.ai})
    assert unchanged == retried

    late_failure =
      Aikido.AiReact.Signals.HandoffFailed.new!(%{
        request_id: original.request_id,
        handoff_id: original.handoff_pending,
        reason: :provider_unavailable
      })

    assert {:ok, unchanged} =
             Aikido.AgentServer.call(pid, late_failure, &{:ok, &1.agent.state.ai})

    assert unchanged == retried

    send(retry, {:answer, {:ok, summary_response("Mission: inspect evidence. Next: finish.")}})
    assert_receive {:request, successor, _, [_]}, 5_000
    send(successor, {:answer, {:ok, summary_response("done")}})
    assert {:ok, "done"} = Task.await(task)
    assert {:ok, %{usage: %{input_tokens: 60, output_tokens: 9}}} = ai(pid)
  end

  test "unusable summaries exhaust the explicit bound without replacing history", ctx do
    for {document, reason} <- [
          {"", :empty_or_invalid_document},
          {String.duplicate("oversized ", 2_000), :document_exceeds_context_limit}
        ] do
      pid = start_server(ctx, Agent)
      opts = regeneration_options(self())

      task =
        Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

      assert_receive {:request, first, _, []}, 5_000
      assert {:ok, original} = ai(pid)
      send(first, {:answer, {:ok, summary_response(document)}})
      assert_receive {:request, retry, _, []}, 5_000
      send(retry, {:answer, {:ok, summary_response(document)}})
      assert {:error, {:context_handoff_failed, ^reason}} = Task.await(task)
      assert {:ok, failed} = ai(pid)
      assert failed.context == original.context
      assert failed.handoff_regenerations == 1
      assert failed.usage.input_tokens == 40
      refute_received {:request, _, _, _}
    end
  end

  test "truncated documents and provider failures are not summary-regenerated", ctx do
    for {response, reason} <- [
          {{:ok, summary_response("partial", :length)}, :truncated_document},
          {{:ok, summary_response("", :length)}, :truncated_document},
          {{:error, :provider_unavailable}, :provider_unavailable}
        ] do
      pid = start_server(ctx, Agent)
      opts = regeneration_options(self())

      task =
        Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

      assert_receive {:request, writer, _, []}, 5_000
      send(writer, {:answer, response})
      assert {:error, {:context_handoff_failed, ^reason}} = Task.await(task)
      assert {:ok, %{handoff_regenerations: 0}} = ai(pid)
      refute_received {:request, _, _, _}
    end
  end

  test "a regenerated summary keeps the original run deadline", ctx do
    pid = start_server(ctx, Agent)
    deadline = System.system_time(:millisecond) + 2_000

    opts =
      regeneration_options(self())
      |> Keyword.put(:metadata, %{aikido_deadline_at: deadline})

    task =
      Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

    assert_receive {:request, first, _, []}, 5_000
    send(first, {:answer, {:ok, summary_response("")}})
    assert_receive {:request, retry, _, []}, 5_000
    monitor = Process.monitor(retry)
    assert {:ok, %{deadline_at: ^deadline}} = ai(pid)
    assert {:error, {:context_handoff_failed, :timeout}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^retry, _}, 5_000
    refute_received {:request, _, _, _}
  end

  test "recovery interrupts a regenerated summary rather than replaying it", ctx do
    pid = start_server(ctx, Agent)
    opts = regeneration_options(self())

    task =
      Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

    assert_receive {:request, first, _, []}, 5_000
    send(first, {:answer, {:ok, summary_response("")}})
    assert_receive {:request, _retry, _, []}, 5_000
    assert {:ok, state} = ai(pid)
    restored = state |> Aikido.AiReact.Slice.externalize() |> Aikido.AiReact.Slice.reinstate()
    assert restored.status == :failed
    assert restored.error == :interrupted
    assert restored.handoff_pending == nil
    assert restored.prepared_tools == nil
    assert restored.context == state.context
    assert restored.handoff_regenerations == 1
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
  end

  test "encoded snapshots restore retry policy and interrupt pending regeneration", ctx do
    pid = start_server(ctx, Agent)
    opts = regeneration_options(self())

    task =
      Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

    assert_receive {:request, first, _, []}, 5_000
    send(first, {:answer, {:ok, summary_response("")}})
    assert_receive {:request, _retry, _, []}, 5_000
    assert {:ok, before} = ai(pid)
    saved = saved_runtime(pid)
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
    :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(ctx.aikido), pid)
    restored = activate_saved(ctx, saved)
    assert {:ok, state} = ai(restored)
    assert state.status == :failed
    assert state.error == :interrupted
    assert state.context == before.context
    assert state.handoff_pending == nil
    assert state.prepared_tools == nil
    assert state.hooks_pending == %{}
    assert state.options.handoff_max_regenerations == 1
    assert state.handoff_regenerations == 1
    refute_received {:request, _, _, _}

    next = Task.async(fn -> Aikido.AI.ask_sync(restored, "continue", opts) end)
    assert_receive {:request, summary, _, []}, 5_000
    assert {:ok, %{handoff_regenerations: 0}} = ai(restored)
    send(summary, {:answer, {:ok, summary_response("Next: finish retained work.")}})
    assert_receive {:request, model, _, [_]}, 5_000
    send(model, {:answer, {:ok, summary_response("done")}})
    assert {:ok, "done"} = Task.await(next)
  end

  test "old encoded snapshots default missing retry fields to zero", ctx do
    pid = start_server(ctx, Agent)
    saved = saved_runtime(pid)
    :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(ctx.aikido), pid)
    envelope = Aikido.Durable.Snapshot.dump(saved)
    {:ok, binary} = Ash.Type.cast_from_embedded(:binary, envelope["payload"])
    {:ok, stored} = Ash.Type.cast_from_embedded(:term, binary)
    {:ok, binary} = Ash.Type.dump_to_embedded(:term, remove_retry_fields(stored))
    {:ok, payload} = Ash.Type.dump_to_embedded(:binary, binary)
    legacy = Aikido.Durable.Snapshot.load(%{envelope | "payload" => payload})
    restored = activate_saved(ctx, legacy)

    assert {:ok, %{handoff_regenerations: 0, options: %{handoff_max_regenerations: 0}}} =
             ai(restored)

    opts = options(self())

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(restored, String.duplicate("evidence ", 1_400), opts)
      end)

    assert_receive {:request, summary, _, []}, 5_000
    send(summary, {:answer, {:ok, summary_response("")}})
    assert {:error, {:context_handoff_failed, :empty_or_invalid_document}} = Task.await(task)
    refute_received {:request, _, _, _}
  end

  defp saved_runtime(pid) do
    {:ok, envelope} =
      Aikido.AgentServer.state(pid, fn runtime ->
        {:ok,
         Aikido.Durable.AgentServer.dump_state(%{
           runtime: runtime,
           options: [agent_module: Agent, id: runtime.id, aikido: runtime.aikido],
           permanent: false
         })}
      end)

    Aikido.Durable.Snapshot.load(envelope)
  end

  defp activate_saved(ctx, saved) do
    durable = Aikido.durable_supervisor_name(ctx.aikido)
    key = "restored-#{System.unique_integer([:positive])}"

    assert {:ok, {pid, _}} =
             DurableServer.Supervisor.start_child(
               durable,
               {Aikido.Durable.AgentServer, key: key, initial_state: saved}
             )

    on_exit(fn ->
      if Process.alive?(pid), do: Aikido.Durable.stop(durable, pid)
    end)

    pid
  end

  # Legacy encoded fixture: the previous schema had neither retry field.
  defp remove_retry_fields(value) when is_map(value) do
    value
    |> Map.drop([
      :handoff_regenerations,
      "handoff_regenerations",
      :handoff_max_regenerations,
      "handoff_max_regenerations"
    ])
    |> Map.new(fn {key, child} -> {key, remove_retry_fields(child)} end)
  end

  defp remove_retry_fields(value) when is_list(value), do: Enum.map(value, &remove_retry_fields/1)

  defp remove_retry_fields(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&remove_retry_fields/1) |> List.to_tuple()

  defp remove_retry_fields(value), do: value

  test "invalid tool-call summaries regenerate and only accepted summaries run after-model hooks",
       ctx do
    pid = start_server(ctx, Agent)

    opts =
      regeneration_options(self())
      |> Keyword.put(:hooks, [
        %{
          name: "accepted_summary",
          event: :after_model,
          mode: :sync,
          script: ~s(return {context = "accepted summary hook"})
        }
      ])

    task =
      Task.async(fn -> Aikido.AI.ask_sync(pid, String.duplicate("evidence ", 1_400), opts) end)

    assert_receive {:request, first, _, []}, 5_000

    invalid = %{
      summary_response("not a summary", :tool_calls)
      | message:
          ReqLLM.Context.assistant("",
            tool_calls: [
              %{id: "not_executable", name: "test_add", arguments: %{a: 1, b: 2}}
            ]
          )
    }

    send(first, {:answer, {:ok, invalid}})
    assert_receive {:request, retry, messages, []}, 5_000
    assert text(List.last(messages)) =~ "without tool calls"
    assert {:ok, %{hook_sequence: 0, pending_tool_calls: []}} = ai(pid)
    send(retry, {:answer, {:ok, summary_response("Next: finish the work.")}})
    assert_receive {:request, successor, messages, [_]}, 5_000
    assert Enum.any?(messages, &(text(&1) =~ "accepted summary hook"))
    assert {:ok, %{hook_sequence: 1}} = ai(pid)
    send(successor, {:answer, {:ok, summary_response("done")}})
    assert {:ok, "done"} = Task.await(task)
  end

  defp regeneration_options(observer) do
    options(observer)
    |> Keyword.update!(:options, &Map.put(&1, :handoff_max_regenerations, 1))
  end

  defp summary_response(text, finish_reason \\ :stop) do
    %ReqLLM.Response{
      id: "summary",
      model: "offline",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant(text, tool_calls: []),
      finish_reason: finish_reason,
      usage: %{input_tokens: 20, output_tokens: 3}
    }
  end

  defp ai(pid), do: Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
  defp text(message), do: Enum.map_join(message.content, &(&1.text || ""))

  test "queued duplicate instructions retain their arrival order through a writer", ctx do
    pid = start_server(ctx, Agent)
    observer = self()
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", options(observer)) end)
    assert_receive {:request, model, _, [_ | _]}, 5_000

    for message <- ["repeat instruction", "middle instruction", "repeat instruction"] do
      assert {:ok, :queued} = Aikido.AI.queue_message(pid, message)
    end

    send(
      model,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "duplicate-input",
          model: "offline",
          context: ReqLLM.Context.new(),
          usage: %{input_tokens: 4_400},
          message:
            ReqLLM.Context.assistant("",
              tool_calls: [
                ReqLLM.ToolCall.new("duplicate-tool", "test_add", ~s({"a":1,"b":2}))
              ]
            ),
          finish_reason: :tool_calls
        }}}
    )

    assert_receive {:request, writer, history, []}, 5_000

    raw = fn messages ->
      messages
      |> Enum.filter(&(&1.role == :user))
      |> Enum.map(&text/1)
      |> Enum.filter(&(&1 in ["repeat instruction", "middle instruction"]))
    end

    expected = ["repeat instruction", "middle instruction", "repeat instruction"]
    assert raw.(history) == expected

    send(
      writer,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "duplicate-writer",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("Continue the actual work", tool_calls: []),
          finish_reason: :stop
        }}}
    )

    assert_receive {:request, successor, fresh, [_ | _]}, 5_000
    assert raw.(fresh) == expected

    send(
      successor,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "duplicate-final",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("done", tool_calls: []),
          finish_reason: :stop
        }}}
    )

    assert {:ok, "done"} = Task.await(task, 5_000)
  end

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
