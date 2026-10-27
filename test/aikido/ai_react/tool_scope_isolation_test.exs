defmodule Aikido.ToolScopeIsolationTest.ObserveNativeScope do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    send(input.context.observer, {:tool_scope, context.actor, context.tenant, input.context.aikido.agent_id})
    {:ok, "observed"}
  end
end

defmodule Aikido.ToolScopeIsolationTest.NativeTool do
  use Ash.Resource, domain: Aikido.ToolScopeIsolationTest.Tools

  actions do
    action :observe, :string do
      run Aikido.ToolScopeIsolationTest.ObserveNativeScope
    end
  end
end

defmodule Aikido.ToolScopeIsolationTest.Tools do
  use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

  resources do
    resource Aikido.ToolScopeIsolationTest.NativeTool
  end

  tools do
    tool :native_scope, Aikido.ToolScopeIsolationTest.NativeTool, :observe
  end
end

defmodule Aikido.ToolScopeIsolationTest.Prepare do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    observer = input.arguments.metadata.observer
    send(observer, {:preparation_scope, context.actor, context.tenant})

    if input.arguments.metadata.native? do
      {:ok, input.arguments.options
        |> Keyword.put(:actions, [{Aikido.ToolScopeIsolationTest.NativeTool, [:observe]}])
        |> Keyword.put(:tools, [:native_scope])}
    else
      tool = ReqLLM.Tool.new!(name: "raw_scope", description: "Observe the executing tool scope",
        parameter_schema: %{"type" => "object", "properties" => %{}}, callback: fn _ -> {:ok, "observed"} end)
      callback = fn _arguments, live ->
        send(observer, {:tool_scope, live[:actor], live[:tenant], live.agent_id})
        {:ok, "observed"}
      end
      {:ok, Keyword.put(input.arguments.options, :extra_tools, [{tool, callback}])}
    end
  end
end

defmodule Aikido.ToolScopeIsolationTest.Preparation do
  use Ash.Resource, domain: Aikido.RuntimeDomain

  actions do
    action :prepare, :term do
      argument :options, {:array, :tuple}, constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]
      argument :metadata, :map
      run Aikido.ToolScopeIsolationTest.Prepare
    end
  end
end

defmodule Aikido.ToolScopeIsolationTest.Client do
  def generate_text(_model, _messages, opts) do
    send(opts[:observer], {:model, self()})
    receive do
      {:response, response} -> {:ok, response}
    end
  end
end

defmodule Aikido.ToolScopeIsolationTest.Agent do
  use Aikido.Agent

  agent do
    name "scoped_tool_execution"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.AiReact.ToolScopeIsolationTest do
  use AikidoTest.Case, async: true
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  test "native scope is the sole source of tool authority for raw and Ash callbacks", ctx do
    observer = self()

    for native? <- [false, true], scope <- [[], [actor: %{id: "executing-agent"}, tenant: "org"]] do
      id = unique_id()
      pid = start_server(ctx, Aikido.ToolScopeIsolationTest.Agent,
        id: id, initial_state: %{ai: %{
          model: "offline", client: Aikido.ToolScopeIsolationTest.Client,
          options: %{tool_preparation: {Aikido.ToolScopeIsolationTest.Preparation, :prepare}},
          tool_options: [actions: []], llm_opts: [observer: observer],
          tool_context: %{actor: %{id: "configuration-is-not-an-actor"}, tenant: "not-a-scope",
                          authorize?: false, context: %{observer: observer}}
        }})
      opts = Keyword.put(scope, :metadata, %{observer: observer, native?: native?})
      task = Task.async(fn -> Aikido.AI.ask_sync(pid, "observe scope", opts) end)
      actor = scope[:actor]
      tenant = scope[:tenant]
      assert_receive {:preparation_scope, ^actor, ^tenant}, 5_000
      assert_receive {:model, model}, 5_000
      name = if native?, do: "native_scope", else: "raw_scope"
      send(model, {:response, Responses.tool_call_response([{name, %{}, "call"}])})
      assert_receive {:tool_scope, ^actor, ^tenant, ^id}, 5_000
      assert_receive {:model, next}, 5_000
      send(next, {:response, Responses.final_answer_response("done")})
      assert {:ok, "done"} = Task.await(task)
    end
  end
end
