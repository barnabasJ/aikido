defmodule Aikido.ToolRefreshTest.Agent do
  use Aikido.Agent

  agent do
    name "refresh_test"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.ToolRefreshTest.Prepare do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, context) do
    source = context.source_context
    version = source[:version] || 1
    observer = input.arguments.metadata.observer
    send(observer, {:preparation, version, self(), context.actor, context.tenant})

    if input.arguments.metadata[:hold],
      do:
        (receive do
           :release -> :ok
         end)

    tool =
      ReqLLM.Tool.new!(
        name: "version",
        description: "version #{version}",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _ -> {:ok, version} end
      )

    {:ok, Keyword.put(input.arguments.options, :extra_tools, [tool])}
  end
end

defmodule Aikido.ToolRefreshTest.Provider do
  use Ash.Resource, domain: Aikido.RuntimeDomain

  actions do
    action :prepare, :term do
      argument :options, {:array, :tuple},
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      argument :metadata, :map
      run Aikido.ToolRefreshTest.Prepare
    end
  end
end

defmodule Aikido.ToolRefreshTest.Client do
  def generate_text(_, _messages, opts) do
    send(opts[:observer], {:model, self(), opts[:tools]})

    receive do
      {:response, response} -> {:ok, response}
    end
  end
end

defmodule Aikido.ToolRefreshTest do
  use AikidoTest.Case, async: true
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  defp options(observer, metadata \\ %{}) do
    [
      model: "offline",
      client: Aikido.ToolRefreshTest.Client,
      options: %{tool_preparation: {Aikido.ToolRefreshTest.Provider, :prepare}},
      metadata: Map.merge(%{observer: observer}, metadata),
      llm_opts: [observer: observer],
      actor: %{id: "caller"},
      tenant: "org"
    ]
  end

  defp refresh(pid, context) do
    signal =
      Aikido.AiReact.Signals.RefreshTools.new!(%{tool_context: %{context: context}})
      |> Aikido.Signal.put_ctx(%{actor: %{id: "caller"}, tenant: "org"})

    Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :accepted} end)
  end

  test "scoped native preparation runs once and refresh waits for a safe model boundary", ctx do
    pid = start_server(ctx, Aikido.ToolRefreshTest.Agent)
    opts = options(self())
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "start", opts) end)
    assert_receive {:preparation, 1, _, %{id: "caller"}, "org"}, 5_000
    assert_receive {:model, model, [%{description: "version 1"}]}, 5_000
    assert {:ok, :accepted} = refresh(pid, %{version: 2})
    refute_received {:preparation, 2, _, _, _}

    response = %ReqLLM.Response{
      id: "tool",
      model: "offline",
      context: ReqLLM.Context.new(),
      finish_reason: :tool_calls,
      message:
        ReqLLM.Context.assistant("", tool_calls: [ReqLLM.ToolCall.new("v", "version", "{}")])
    }

    send(model, {:response, response})
    assert_receive {:preparation, 2, _, %{id: "caller"}, "org"}, 5_000
    assert_receive {:model, next, [%{description: "version 2"}]}, 5_000
    send(next, {:response, Responses.final_answer_response("done")})
    assert {:ok, "done"} = Task.await(task)
    assert {:ok, ai} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
    assert ai.tools_generation == 2
    assert ai.prepared_tools == nil
    assert ai.tool_context.context.version == 2
  end

  test "refresh during setup cancels the old generation and rejects late readiness", ctx do
    pid = start_server(ctx, Aikido.ToolRefreshTest.Agent)
    opts = options(self(), %{hold: true})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "start", opts) end)
    assert_receive {:preparation, 1, old, _, _}, 5_000
    monitor = Process.monitor(old)
    assert {:ok, :accepted} = refresh(pid, %{version: 2})
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    assert_receive {:preparation, 2, current, _, _}, 5_000
    assert {:ok, id} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.request_id})

    late =
      Aikido.AiReact.Signals.ToolsReady.new!(%{
        request_id: id,
        generation: 1,
        prepared_tools: {[], %{}}
      })

    assert {:ok, :setup} = Aikido.AgentServer.call(pid, late, &{:ok, &1.agent.state.ai.status})
    send(current, :release)
    assert_receive {:model, model, [%{description: "version 2"}]}, 5_000
    send(model, {:response, Responses.final_answer_response("done")})
    assert {:ok, "done"} = Task.await(task)
  end
end
