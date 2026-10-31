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

defmodule Aikido.AiReact.Directives.ToolExecTest.TransferFailureTracer do
  @moduledoc "Fails actual tool-attempt context transfer after the outer tool span starts."
  @behaviour Ash.Tracer

  @span {__MODULE__, :span}
  @parents {__MODULE__, :parents}

  @impl true
  def start_span(type, _name) do
    Process.put(@parents, [Process.get(@span) | Process.get(@parents, [])])
    Process.put(@span, if(type == {:custom, :aikido_tool_call}, do: :tool_call, else: :other))
    :ok
  end

  @impl true
  def stop_span do
    case Process.get(@parents, []) do
      [parent | rest] ->
        Process.put(@span, parent)
        Process.put(@parents, rest)

      [] ->
        Process.delete(@span)
    end

    :ok
  end

  @impl true
  def get_span_context do
    case Process.get(@span) do
      :tool_call -> {:tool_call, self()}
      span -> span
    end
  end

  @impl true
  def set_span_context({:tool_call, starter}) do
    if List.first(Process.get(:"$callers", [])) == starter do
      raise "tool transfer stack probe"
    end

    Process.put(@span, :other)
    :ok
  end

  def set_span_context(span) do
    Process.put(@span, span)
    :ok
  end

  @impl true
  def set_metadata(_type, _metadata), do: :ok

  @impl true
  def set_error(_error, _options), do: :ok
end

defmodule Aikido.AiReact.Directives.ToolExecTest do
  use AikidoTest.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

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

  test "runtime exceptions log a payload-free classification with the delivered reference",
       context do
    task = %{
      directive()
      | registry: %{"test_add" => fn _, _ -> raise "synthetic-credential-in-runtime-message" end},
        tool_context: %{context: %{api_key: "context-credential-sentinel"}}
    }

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task) end)
    content = Jason.decode!(signal.data.content)

    assert signal.data.error?
    assert content["code"] == "tool_runtime_failure"
    assert log =~ "Tool test_add failed (RuntimeError)"
    assert log =~ "reference #{content["reference"]}; reason "
    assert log =~ "kind=exception code=exception exception=RuntimeError stack=stack_unavailable"
    refute log =~ "synthetic-credential-in-runtime-message"
    assert length(Regex.scan(~r/Tool test_add failed/, log)) == 1
    refute signal.data.content =~ "synthetic-credential-in-runtime-message"
    refute log =~ "context-credential-sentinel"
  end

  test "runtime exits retain classification without arbitrary reason fields", context do
    task = %{
      directive()
      | registry: %{
          "test_add" => fn _, _ ->
            exit(
              {:tool_runtime_probe,
               %{message: "exit diagnostic sentinel", api_key: "private-key"}}
            )
          end
        }
    }

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task) end)
    content = Jason.decode!(signal.data.content)

    assert signal.data.error?
    assert content["code"] == "tool_runtime_failure"
    assert log =~ "Tool test_add failed (runtime failure)"
    assert log =~ "reference #{content["reference"]}; reason "
    assert log =~ "kind=exit code=unknown_runtime_failure exception=none stack=stack_unavailable"
    refute log =~ "tool_runtime_probe"
    refute log =~ "exit diagnostic sentinel"
    refute log =~ "private-key"
    refute signal.data.content =~ "exit diagnostic sentinel"
  end

  test "runtime diagnostics bound large reasons without changing the completion", context do
    task = %{
      directive()
      | registry: %{
          "test_add" => fn _, _ ->
            throw(String.duplicate("synthetic-private-throw-text", 2_000))
          end
        }
    }

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task) end)
    content = Jason.decode!(signal.data.content)

    assert content["code"] == "tool_runtime_failure"
    assert log =~ "reference #{content["reference"]}; reason "
    assert log =~ "kind=throw code=unknown_runtime_failure exception=none stack=stack_unavailable"
    refute log =~ "synthetic-private-throw-text"
    refute signal.data.content =~ "synthetic-private-throw-text"
    assert byte_size(log) < 1_300
  end

  test "malformed runtime reasons fall back while preserving their reference", context do
    task = %{
      directive()
      | registry: %{"test_add" => fn _, _ -> throw([:diagnostic | :improper_tail]) end}
    }

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task) end)
    content = Jason.decode!(signal.data.content)

    assert signal.data.error?
    assert content["code"] == "tool_runtime_failure"
    assert log =~ "reference #{content["reference"]}; reason "
    assert log =~ "kind=throw code=unknown_runtime_failure exception=none stack=stack_unavailable"
    refute log =~ "improper_tail"
    refute signal.data.content =~ "improper_tail"
  end

  test "private typed runtime causes stay internal despite the diagnostic projection", context do
    task = %{
      directive()
      | registry: %{
          "test_add" => fn _, _ ->
            raise Aikido.Agent.Errors.RuntimeUnavailable,
              reason:
                {:timeout,
                 {GenServer, :call, [self(), %{input: "synthetic-private-runtime-cause"}, 5_000]}}
          end
        }
    }

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task) end)
    content = Jason.decode!(signal.data.content)

    assert signal.data.error?
    assert content["code"] == "tool_runtime_failure"
    assert log =~ "reference #{content["reference"]}; reason "
    assert log =~ "exception=Aikido.Agent.Errors.RuntimeUnavailable"
    assert log =~ "stack=stack_unavailable"
    assert length(Regex.scan(~r/Tool test_add failed/, log)) == 1
    refute log =~ "synthetic-private-runtime-cause"
    refute signal.data.content =~ "synthetic-private-runtime-cause"
  end

  test "known structural exit codes omit their supplied payload", context do
    task = %{
      directive()
      | registry: %{
          "test_add" => fn _, _ ->
            exit({:badmatch, %{input: "synthetic-private-badmatch-payload"}})
          end
        }
    }

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task) end)
    content = Jason.decode!(signal.data.content)

    assert signal.data.error?
    assert log =~ "reference #{content["reference"]}; reason "
    assert log =~ "kind=exit code=badmatch exception=none stack=stack_unavailable"
    refute log =~ "synthetic-private-badmatch-payload"
    refute signal.data.content =~ "synthetic-private-badmatch-payload"
  end

  test "an actual attempt transfer crash supplies argument-free runtime stack frames", context do
    options = Aikido.AiReact.Options.new!(%{tool_max_retries: 0})
    task = directive(options: options)

    input =
      Aikido.Signal.new!("input", %{})
      |> Aikido.Signal.put_ctx(%{tracer: __MODULE__.TransferFailureTracer})

    {signal, log} = with_log([level: :error], fn -> run_tool(context, task, input) end)
    content = Jason.decode!(signal.data.content)

    diagnostic =
      log
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "reference #{content["reference"]}; reason "))

    assert signal.data.error?
    assert content["code"] == "tool_runtime_failure"
    assert is_binary(diagnostic)
    assert diagnostic =~ "kind=exception code=exception exception=RuntimeError stack=["
    assert diagnostic =~ "TransferFailureTracer.set_span_context/1"
    assert length(Regex.scan(~r/Tool test_add failed/, log)) == 1
    refute diagnostic =~ "tool transfer stack probe"
    refute diagnostic =~ "tool_call}"
    refute diagnostic =~ ".ex:"
    refute signal.data.content =~ "tool transfer stack probe"
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
