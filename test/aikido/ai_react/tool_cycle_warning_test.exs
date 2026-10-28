defmodule Aikido.ToolCycleWarningTest.Journal do
  @moduledoc false
  use Aikido.Middleware

  def on_signal(signal, context, _options, next) do
    before = warnings(context.agent.state.ai.context)

    with {:ok, updated, directives} <- next.(signal, context) do
      added = warnings(updated.agent.state.ai.context) -- before

      entries =
        Enum.map(added, fn message ->
          %{
            kind: :ai_message,
            payload: %{
              role: message.role,
              content: Enum.map_join(message.content, &(&1.text || "")),
              message_metadata: message.metadata
            },
            refs: %{request_id: updated.agent.state.ai.request_id}
          }
        end)

      append =
        if entries == [],
          do: [],
          else: [
            Aikido.Directives.emit_to_pid(
              Aikido.Thread.Signals.Append.new!(%{entry: entries}),
              updated.agent_pid
            )
          ]

      {:ok, updated, append ++ directives}
    end
  end

  defp warnings(nil), do: []

  defp warnings(context),
    do:
      Enum.filter(
        context.messages,
        &Map.has_key?(&1.metadata, :aikido_tool_cycle_warning)
      )
end

defmodule Aikido.ToolCycleWarningTest.Agent do
  use Aikido.Agent

  agent do
    name "tool_cycle_warning"
    slice :ai, Aikido.AiReact.Slice
    slice :thread, Aikido.Thread.Slice
    middleware [Aikido.ToolCycleWarningTest.Journal]
  end
end

defmodule Aikido.ToolCycleWarningTest.Client do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model_request, self(), messages, opts[:tools]})

    receive do
      {:answer, result} -> result
    end
  end
end

defmodule Aikido.ToolCycleWarningTest.Keys do
  def tagged(batch, tag), do: {:ok, {tag, batch}}
end

defmodule Aikido.ToolCycleWarningTest do
  use AikidoTest.Case, async: false
  alias Aikido.ToolCycleWarningTest.{Agent, Client, Keys}
  alias Aikido.AiReact.Types.ToolCycleWarning

  test "period-one-to-four warning facts reach Thread once before handoff and remain after settlement",
       ctx do
    assert {:ok, constraints} = Ash.Type.init(ToolCycleWarning, [])

    for period <- 1..4, callback <- [nil, {Keys, :tagged, ["custom"]}] do
      pid = start_server(ctx, Agent)

      {:ok, note_ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "aikido.thread.append",
          fn runtime ->
            case runtime.agent.state.thread.entries do
              [entry] -> {:ok, entry}
              _ -> :skip
            end
          end,
          once: true
        )

      options = [
        model: "offline",
        client: Client,
        tools: [:test_add],
        max_iterations: 30,
        llm_opts: [observer: self()],
        timeout: 15_000,
        options: %{
          context_max_tokens: 5_000,
          handoff_buffer_tokens: 1_000,
          max_repeated_tool_cycles: 5,
          tool_loop_key: callback
        }
      ]

      request =
        Task.async(fn -> Aikido.AI.ask_sync(pid, "repeat the controlled cycle", options) end)

      for index <- 1..(period * 5) do
        assert_receive {:model_request, model, _messages, [_]}, 5_000
        tokens = if index in [period * 3, period * 5], do: 4_400, else: 100
        response = tool_response("call-#{index}", rem(index - 1, period), tokens)
        send(model, {:answer, {:ok, response}})

        if index == period * 3 do
          assert_receive {:model_request, summary, summary_messages, []}, 5_000

          [warning_message] =
            Enum.filter(
              summary_messages,
              &Map.has_key?(&1.metadata, :aikido_tool_cycle_warning)
            )

          payload = warning_message.metadata.aikido_tool_cycle_warning

          assert {:ok, warning} =
                   Ash.Type.cast_from_embedded(ToolCycleWarning, payload, constraints)

          assert warning.period == period
          assert warning.repetitions == 3
          assert warning.iteration == period * 3
          assert_receive {:aikido_subscription, ^note_ref, %{result: {:ok, entry}}}, 5_000
          assert entry.refs.request_id == warning.request_id
          assert entry.payload.message_metadata.aikido_tool_cycle_warning == payload
          assert {:ok, before_handoff} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
          assert before_handoff.request_id == warning.request_id
          assert before_handoff.handoff_pending != nil
          assert_snapshot_warning(pid, payload)
          send(summary, {:answer, {:ok, final_response("Continue the same controlled cycle.")}})
        end
      end

      assert {:error, {:tool_cycle_limit, ^period, 5}} = Task.await(request, 5_000)

      assert {:ok, {ai, [entry]}} =
               Aikido.AgentServer.state(
                 pid,
                 &{:ok, {&1.agent.state.ai, &1.agent.state.thread.entries}}
               )

      assert ai.handoff_count == 1
      assert ai.handoff_pending == nil

      refute Enum.any?(
               ai.context.messages,
               &Map.has_key?(&1.metadata, :aikido_tool_cycle_warning)
             )

      assert {:ok, warning} =
               Ash.Type.cast_from_embedded(
                 ToolCycleWarning,
                 entry.payload.message_metadata.aikido_tool_cycle_warning,
                 constraints
               )

      assert warning.request_id == ai.request_id
      assert warning.period == period
      assert entry.refs.request_id == warning.request_id
      assert_snapshot_warning(pid, entry.payload.message_metadata.aikido_tool_cycle_warning)
      refute_received {:aikido_subscription, ^note_ref, _}
      refute_received {:model_request, _, _, _}
    end
  end

  defp assert_snapshot_warning(pid, payload) do
    assert {:ok, envelope} =
             Aikido.AgentServer.state(pid, fn runtime ->
               {:ok,
                Aikido.Durable.AgentServer.dump_state(%{
                  runtime: runtime,
                  permanent: false,
                  options: [agent_module: Agent, id: runtime.id, aikido: runtime.aikido]
                })}
             end)

    assert {:agent, loaded} = Aikido.Durable.Snapshot.load(envelope).agent
    assert [entry] = loaded.state.thread.entries
    assert entry.payload.message_metadata.aikido_tool_cycle_warning == payload
    assert {:ok, constraints} = Ash.Type.init(ToolCycleWarning, [])
    assert {:ok, _warning} = Ash.Type.cast_from_embedded(ToolCycleWarning, payload, constraints)
  end

  defp tool_response(id, value, tokens) do
    %ReqLLM.Response{
      id: id,
      model: "offline",
      context: ReqLLM.Context.new(),
      usage: %{input_tokens: tokens},
      finish_reason: :tool_calls,
      message:
        ReqLLM.Context.assistant("",
          tool_calls: [
            ReqLLM.ToolCall.new(id, "test_add", Jason.encode!(%{input: %{a: value, b: 2}}))
          ]
        )
    }
  end

  defp final_response(text) do
    %ReqLLM.Response{
      id: "summary",
      model: "offline",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop
    }
  end
end
