defmodule Aikido.ToolLoopKeyTest.Agent do
  use Ash.Resource,
    domain: Aikido.RuntimeDomain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "tool_loop_key"
  end
end

defmodule Aikido.ToolLoopKeyTest.CheckpointAgent do
  use Ash.Resource,
    domain: Aikido.RuntimeDomain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "legacy_tool_loop_key"
  end

  @impl true
  def checkpoint(agent, _context), do: {:ok, %{agent: agent}}

  @impl true
  def restore(%{agent: agent}, _context), do: {:ok, agent}
end

defmodule Aikido.ToolLoopKeyTest.Client do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model_request, self(), messages, opts[:tools]})

    receive do
      {:answer, result} -> result
    end
  end
end

defmodule Aikido.ToolLoopKeyTest.Keys do
  def names(batch, tag),
    do: {:ok, {tag, Enum.map(batch, fn {name, _arguments, _content} -> name end)}}

  def fail(_batch), do: {:error, :cannot_compare}
end

defmodule Aikido.ToolLoopKeyTest do
  use AikidoTest.Case, async: false
  alias Aikido.ToolLoopKeyTest.{Agent, Client, Keys}

  test "native detection stops after adopted results before a pressure-triggered handoff", ctx do
    pid = start_server(ctx, Agent)
    opts = options(self(), {Keys, :names, ["application"]})
    request = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", opts) end)
    assert_receive {:model_request, first, _, [_]}, 5_000
    send(first, {:answer, {:ok, tool_response("first", 1, 100)}})
    assert_receive {:model_request, second, messages, [_]}, 5_000
    assert Enum.count(messages, &(&1.role == :tool)) == 1
    tool_messages = Enum.filter(messages, &(&1.role == :tool))

    assert Enum.all?(tool_messages, &(!Map.get(&1.metadata, :aikido_tool_error?, false))),
           inspect(for(message <- tool_messages, part <- message.content, do: part.text),
             limit: :infinity
           )

    send(second, {:answer, {:ok, tool_response("second", 2, 4_400)}})
    assert {:error, {:tool_cycle_limit, 1, 2}} = Task.await(request, 5_000)
    assert {:ok, state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
    assert state.status == :failed
    assert state.handoff_pending == nil
    assert state.handoff_count == 0
    assert Enum.count(state.context.messages, &(&1.role == :tool)) == 2
    assert state.usage.input_tokens == 4_500
    assert length(state.tool_batch_history) == 2
    assert Enum.all?(state.tool_batch_history, &(byte_size(&1) == 64))
    refute_received {:model_request, _, _, _}
  end

  test "callback failure preserves the tool result and never schedules another model", ctx do
    pid = start_server(ctx, Agent)
    opts = options(self(), {Keys, :fail, []})
    request = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", opts) end)
    assert_receive {:model_request, model, _, [_]}, 5_000
    send(model, {:answer, {:ok, tool_response("first", 1, 4_400)}})
    assert {:error, {:tool_loop_key_failed, {Keys, :fail, :cannot_compare}}} = Task.await(request)
    assert {:ok, state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
    assert Enum.count(state.context.messages, &(&1.role == :tool)) == 1
    assert state.handoff_count == 0
    refute_received {:model_request, _, _, _}
  end

  test "native snapshot encoding retains the configured MFA without a callback closure", ctx do
    pid = start_server(ctx, Agent)
    callback = {Keys, :names, ["persistent"]}
    opts = options(self(), callback)
    request = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", opts) end)
    assert_receive {:model_request, _, _, [_]}, 5_000

    assert {:ok, envelope} =
             Aikido.AgentServer.state(pid, fn runtime ->
               {:ok,
                Aikido.Durable.AgentServer.dump_state(%{
                  runtime: runtime,
                  permanent: false,
                  options: [agent_module: Agent, id: runtime.id, aikido: runtime.aikido]
                })}
             end)

    assert {:agent, restored} = Aikido.Durable.Snapshot.load(envelope).agent
    assert restored.state.ai.options.tool_loop_key == callback
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(request)
  end

  test "an opaque legacy checkpoint can run tools with the missing key default", ctx do
    resource = Aikido.ToolLoopKeyTest.CheckpointAgent
    pid = start_server(ctx, resource)
    durable = Aikido.durable_supervisor_name(ctx.aikido)

    assert {:ok, envelope} =
             Aikido.AgentServer.state(pid, fn runtime ->
               {:ok,
                Aikido.Durable.AgentServer.dump_state(%{
                  runtime: runtime,
                  permanent: false,
                  options: [agent_module: resource, id: runtime.id, aikido: runtime.aikido]
                })}
             end)

    {:ok, binary} = Ash.Type.cast_from_embedded(:binary, envelope["payload"])
    {:ok, saved} = Ash.Type.cast_from_embedded(:term, binary)
    # Change only the historical checkpoint's options representation.
    # Preserve the native agent and slice structs and every unrelated field.
    {:checkpoint, %{agent: checkpoint_agent} = checkpoint} = saved.agent

    legacy_options =
      checkpoint_agent.state.ai.options
      |> Map.from_struct()
      |> Map.delete(:tool_loop_key)

    legacy_ai = %{checkpoint_agent.state.ai | options: legacy_options}
    legacy_agent = %{checkpoint_agent | state: Map.put(checkpoint_agent.state, :ai, legacy_ai)}
    legacy_saved = %{saved | agent: {:checkpoint, %{checkpoint | agent: legacy_agent}}}
    {:ok, binary} = Ash.Type.dump_to_embedded(:term, legacy_saved)
    {:ok, payload} = Ash.Type.dump_to_embedded(:binary, binary)
    loaded = Aikido.Durable.Snapshot.load(%{envelope | "payload" => payload})
    assert {:checkpoint, %{agent: legacy}} = loaded.agent
    refute Map.has_key?(legacy.state.ai.options, :tool_loop_key)
    :ok = Aikido.Durable.stop(durable, pid)

    assert {:ok, {restored, _}} =
             DurableServer.Supervisor.start_child(
               durable,
               {Aikido.Durable.AgentServer,
                key: "legacy-key-#{System.unique_integer([:positive])}", initial_state: loaded}
             )

    on_exit(fn -> if Process.alive?(restored), do: Aikido.Durable.stop(durable, restored) end)

    assert {:ok, restored_options} =
             Aikido.AgentServer.state(
               restored,
               &{:ok, &1.agent.state.ai.options}
             )

    refute Map.has_key?(restored_options, :tool_loop_key)
    opts = options(self(), nil) |> Keyword.delete(:options)
    request = Task.async(fn -> Aikido.AI.ask_sync(restored, "work", opts) end)
    assert_receive {:model_request, model, _, [_]}, 5_000
    send(model, {:answer, {:ok, tool_response("legacy", 1, 100)}})
    assert_receive {:model_request, successor, messages, [_]}, 5_000
    assert Enum.count(messages, &(&1.role == :tool)) == 1
    tool_messages = Enum.filter(messages, &(&1.role == :tool))

    assert Enum.all?(tool_messages, &(!Map.get(&1.metadata, :aikido_tool_error?, false))),
           inspect(for(message <- tool_messages, part <- message.content, do: part.text),
             limit: :infinity
           )

    assert {:ok, adopted} = Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.ai})
    tool_message = Enum.find(adopted.context.messages, &(&1.role == :tool))

    assistant_message =
      Enum.find(
        adopted.context.messages,
        &(&1.role == :assistant && &1.tool_calls not in [nil, []])
      )

    [call] = assistant_message.tool_calls
    content = Enum.map_join(tool_message.content, &(&1.text || ""))

    expected =
      [{ReqLLM.ToolCall.name(call), ReqLLM.ToolCall.args_map(call), content}]
      |> Enum.sort()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert byte_size(adopted.previous_tool_signature) == 64
    assert adopted.previous_tool_signature == expected

    send(
      successor,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "done",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("done"),
          finish_reason: :stop
        }}}
    )

    assert {:ok, "done"} = Task.await(request)
  end

  defp options(observer, callback) do
    [
      model: "offline",
      client: Client,
      tools: [:test_add],
      llm_opts: [observer: observer],
      timeout: 10_000,
      options: %{
        context_max_tokens: 5_000,
        handoff_buffer_tokens: 1_000,
        max_repeated_tool_cycles: 2,
        tool_loop_key: callback
      }
    ]
  end

  defp tool_response(id, a, tokens) do
    %ReqLLM.Response{
      id: id,
      model: "offline",
      context: ReqLLM.Context.new(),
      usage: %{input_tokens: tokens, output_tokens: 20},
      finish_reason: :tool_calls,
      message:
        ReqLLM.Context.assistant("",
          tool_calls: [
            ReqLLM.ToolCall.new(id, "test_add", Jason.encode!(%{input: %{a: a, b: 2}}))
          ]
        )
    }
  end
end
