defmodule Aikido.AiReact.Directives.ToolExecTest.Signals.RunTool do
  use Aikido.Signal

  signal do
    type "test.tool.run"

    schema do
      attribute :directive, Aikido.Types.Directive do
        description "Prepared tool execution requested by this scenario."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.AiReact.Directives.ToolExecTest.Actions.RunTool do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{
        status: :running,
        request_id: input.arguments.directive.request_id
      },
      directives: [input.arguments.directive]
    )
  end
end

defmodule Aikido.AiReact.Directives.ToolExecTest.Actions.RecordResult do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{
        status: :completed,
        last_signal: input.context.aikido.signal
      }
    )
  end
end

defmodule Aikido.AiReact.Directives.ToolExecTest.Agent do
  use Aikido.Agent

  agent do
    name "tool_execution_scenario"
    path :ai
    persistence :temporary

    schema do
      attribute :request_id, :string do
        description "Correlation of the currently executing tool."
      end

      attribute :status, Aikido.AiReact.Types.Status do
        description "Whether the requested tool is running or has returned."
        default :idle
        allow_nil? false
      end

      attribute :last_signal, :term do
        description "Completed tool envelope observed by the receiving action."
      end
    end

    route Aikido.AiReact.Directives.ToolExecTest.Signals.RunTool,
          Aikido.AiReact.Directives.ToolExecTest.Actions.RunTool

    route Aikido.AiReact.Signals.ToolResult,
          Aikido.AiReact.Directives.ToolExecTest.Actions.RecordResult,
          public?: false
  end
end

defmodule Aikido.AiReact.Directives.ToolExecTest do
  use AikidoTest.Case, async: true

  alias Aikido.AiReact.Directives.ToolExec
  @receive_timeout 5_000

  defp directive(opts \\ []) do
    call =
      Keyword.get(opts, :tool_call, %{
        id: "call_1",
        name: "test_add",
        arguments: %{"input" => %{"a" => 1, "b" => 2}}
      })

    ToolExec.new!(
      tool_call: call,
      options: Keyword.get(opts, :options, Aikido.AiReact.Options.new!(%{})),
      registry:
        AshAi.build_tools_and_registry(
          otp_app: :aikido,
          tools: Keyword.get(opts, :tools, [:test_add, :test_fails])
        )
        |> elem(1),
      request_id: Keyword.get(opts, :request_id, "req_1")
    )
  end

  defp run_tool(context, tool, input \\ Aikido.Signal.new!("test.tool.run", %{})) do
    agent = start_server(context, __MODULE__.Agent)
    signal = %{input | type: "test.tool.run", data: %{directive: tool}}

    {:ok, completed} =
      Aikido.AgentServer.call_until(
        agent,
        signal,
        "ai.react.tool.completed",
        &{:ok, &1.agent.state.ai.last_signal},
        timeout: @receive_timeout
      )

    completed
  end

  test "runs the tool and casts ai.react.tool.completed with JSON-encoded result",
       context do
    signal = run_tool(context, directive())
    assert signal.type == "ai.react.tool.completed"
    assert signal.data.tool_call_id == "call_1"
    assert signal.data.name == "test_add"
    assert signal.data.request_id == "req_1"
    assert Jason.decode!(signal.data.content) == %{"result" => 3}
  end

  test "a real tool deadline emits a correlated timeout completion envelope", context do
    options = Aikido.AiReact.Options.new!(%{tool_timeout_ms: 100, tool_max_retries: 0})

    task =
      directive(
        tool_call: %{id: "timed_call", name: "test_wait", arguments: %{}},
        tools: [:test_wait],
        options: options
      )

    owner = self()
    task = %{task | tool_context: %{context: %{observer: owner}}}

    signal = run_tool(context, task)
    assert_receive {:tool_running, worker}, @receive_timeout
    refute Process.alive?(worker)
    assert signal.type == "ai.react.tool.completed"
    assert signal.data.request_id == "req_1"
    assert signal.data.tool_call_id == "timed_call"
    assert signal.data.name == "test_wait"
    assert signal.data.error?
    assert Jason.decode!(signal.data.content)["error"] =~ "Tool timeout"
  end

  test "returns native Ash AI error content inside tool.completed (not failed)",
       context do
    failing =
      directive(
        tool_call: %{
          id: "call_2",
          name: "test_fails",
          arguments: %{"input" => %{"reason" => "nope"}}
        }
      )

    signal = run_tool(context, failing)
    assert signal.type == "ai.react.tool.completed"
    assert signal.data.content =~ "nope"
  end

  test "completion signals carry native Ash scope and explicit application context",
       context do
    start_supervised!(AikidoTest.Support.TestTracer)

    input =
      Aikido.Signal.new!("input", %{})
      |> Aikido.Signal.put_ctx(%{
        actor: %{id: "alice"},
        tenant: "org-a",
        authorize?: true,
        tracer: AikidoTest.Support.TestTracer,
        context: %{shared: %{locale: "de"}, local_only: "stay here"},
        runtime_only: "stay here"
      })

    signal = run_tool(context, directive(), input)

    assert Aikido.Signal.ctx(signal) == %{
             actor: %{id: "alice"},
             tenant: "org-a",
             authorize?: true,
             tracer: [AikidoTest.Support.TestTracer],
             context: %{shared: %{locale: "de"}, local_only: "stay here"}
           }
  end

  test "encodes a 'tool not found' error when the prepared registry has no matching name",
       context do
    missing =
      directive(tool_call: %{id: "call_3", name: "ghost", arguments: %{}})

    signal = run_tool(context, missing)
    assert signal.type == "ai.react.tool.completed"
    assert signal.data.error?
    error = Jason.decode!(signal.data.content)
    assert error["code"] == "tool_not_available"
    assert error["error"] =~ "ghost"
    assert error["available_tools"] == ["test_add", "test_fails"]
    assert error["recovery"] =~ "Use an exact name"
  end

  test "runtime exceptions provide recovery guidance without exposing exception data", context do
    task = %{directive() | registry: %{"test_add" => fn _, _ -> raise "secret-api-key" end}}

    signal = run_tool(context, task)
    assert signal.data.error?
    content = Jason.decode!(signal.data.content)
    assert content["code"] == "tool_runtime_failure"
    assert content["error"] =~ "Inspect the target state before retrying"
    assert content["reference"]
    refute signal.data.content =~ "secret-api-key"
  end

  test "opaque native errors identify the tool and discourage blind retries", context do
    task = %{
      directive()
      | registry: %{"test_add" => fn _, _ -> {:error, "unexpected error occurred"} end}
    }

    signal = run_tool(context, task)
    assert signal.data.error?
    assert signal.data.content =~ "test_add"
    assert signal.data.content =~ "Do not repeat the same call unchanged"
  end
end
