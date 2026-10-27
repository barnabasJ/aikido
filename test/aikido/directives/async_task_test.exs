defmodule Aikido.Directives.AsyncTaskTest.Signals.RunWork do
  use Aikido.Signal

  signal do
    type "test.async_task"

    schema do
      attribute :request_id, :string do
        description "Correlation supplied with this background work request."
      end

      attribute :directive, Aikido.Types.Directive do
        description "Supervised work requested by the agent's action."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.Directives.AsyncTaskTest.Actions.RunWork do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [input.arguments.directive]
    )
  end
end

defmodule Aikido.Directives.AsyncTaskTest.Actions.RecordResult do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | value: Map.delete(input.arguments.data, :directive)}
    )
  end
end

defmodule Aikido.Directives.AsyncTaskTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "async_task_test_agent"
    path :domain

    schema do
      attribute :value, :term do
        description "Domain value used to verify state transitions and native contracts."
        default nil
      end
    end

    route Aikido.Directives.AsyncTaskTest.Signals.RunWork,
          Aikido.Directives.AsyncTaskTest.Actions.RunWork

    route "**", Aikido.Directives.AsyncTaskTest.Actions.RecordResult, public?: false
  end
end

defmodule Aikido.Directives.AsyncTaskTest.Work do
  @moduledoc false
  @spec ok(test_pid :: pid()) :: {:ok, map()}
  def ok(test_pid) do
    send(test_pid, :ok_work_ran)
    {:ok, %{answer: 42}}
  end

  @spec error(test_pid :: pid()) :: {:error, atom()}
  def error(test_pid) do
    send(test_pid, :error_work_ran)
    {:error, :boom}
  end

  @spec plain(test_pid :: pid()) :: String.t()
  def plain(test_pid) do
    send(test_pid, :plain_work_ran)
    "plain-result"
  end

  @spec custom_signal() :: Aikido.Signal.t()
  def custom_signal do
    Aikido.Signal.new!("custom.done", %{value: 7}, source: "/work/custom")
  end

  @spec multiple_signals() :: {:signals, [Aikido.Signal.t()]}
  def multiple_signals do
    {:signals,
     [
       Aikido.Signal.new!("custom.one", %{index: 1}, source: "/work/multi"),
       Aikido.Signal.new!("custom.two", %{index: 2}, source: "/work/multi")
     ]}
  end

  @spec raise_error() :: no_return()
  def raise_error do
    raise ArgumentError, "bad input"
  end

  @spec throw_value() :: no_return()
  def throw_value do
    throw(:thrown_value)
  end

  @spec exit_value() :: no_return()
  def exit_value do
    exit(:exited_value)
  end
end

defmodule Aikido.Directives.AsyncTaskTest do
  use AikidoTest.Case, async: true

  setup context do
    agent = start_server(context, __MODULE__.TestAgent, id: "async-task-agent")

    {:ok, _} =
      Aikido.AgentServer.subscribe(agent, "**", fn _, event ->
        if event.signal.type == "test.async_task", do: :skip, else: {:ok, event.signal}
      end)

    %{agent: agent}
  end

  defp run_directive(agent, directive) do
    signal =
      Aikido.Signal.new!("test.async_task", %{request_id: "req_1", directive: directive},
        source: "/test"
      )

    {:ok, :accepted} = Aikido.AgentServer.call(agent, signal, fn _ -> {:ok, :accepted} end)
    :ok
  end

  test("wraps {:ok, result} in the configured success signal", %{agent: agent}) do
    test_pid = self()

    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :ok, [test_pid]},
        success_type: "work.completed",
        error_type: "work.failed",
        payload: %{request_id: "req_1"}
      )

    assert :ok = run_directive(agent, directive)

    assert_receive :ok_work_ran, 1000
    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.completed"
    assert signal.source == "/agent/async-task-agent/async_task"
    assert signal.data == %{request_id: "req_1", result: %{answer: 42}}
  end

  test("wraps {:error, reason} in the configured error signal", %{agent: agent}) do
    test_pid = self()

    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :error, [test_pid]},
        success_type: "work.completed",
        error_type: "work.failed",
        payload: %{request_id: "req_2"}
      )

    assert :ok = run_directive(agent, directive)

    assert_receive :error_work_ran, 1000
    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.failed"
    assert signal.data == %{request_id: "req_2", reason: :boom}
  end

  test("wraps plain return values as success results", %{agent: agent}) do
    test_pid = self()

    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :plain, [test_pid]},
        success_type: "work.completed"
      )

    assert :ok = run_directive(agent, directive)

    assert_receive :plain_work_ran, 1000
    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.completed"
    assert signal.data == %{result: "plain-result"}
  end

  test("casts a signal returned by the MFA without wrapping it", %{agent: agent}) do
    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :custom_signal, []})

    assert :ok = run_directive(agent, directive)

    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "custom.done"
    assert signal.source == "/work/custom"
    assert signal.data == %{value: 7}
  end

  test("casts every signal returned by {:signals, signals}", %{agent: agent}) do
    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :multiple_signals, []})

    assert :ok = run_directive(agent, directive)

    assert_receive {:aikido_subscription, _, %{result: {:ok, first}}}, 1000
    assert_receive {:aikido_subscription, _, %{result: {:ok, second}}}, 1000
    assert first.type == "custom.one"
    assert first.data == %{index: 1}
    assert second.type == "custom.two"
    assert second.data == %{index: 2}
  end

  test("passes runtime context to unary function work", %{agent: agent}) do
    directive =
      Aikido.Directives.async_task(
        fn context ->
          {:ok, %{agent_id: context.agent_id, input_type: context.input_signal.type}}
        end,
        success_type: "work.context"
      )

    assert :ok = run_directive(agent, directive)

    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.context"

    assert signal.data == %{
             result: %{agent_id: "async-task-agent", input_type: "test.async_task"}
           }
  end

  test("converts raised exceptions into error signals", %{agent: agent}) do
    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :raise_error, []},
        error_type: "work.failed"
      )

    assert :ok = run_directive(agent, directive)

    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.failed"
    assert signal.data.kind == :error
    assert %ArgumentError{message: "bad input"} = signal.data.reason
  end

  test("converts thrown values into error signals", %{agent: agent}) do
    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :throw_value, []},
        error_type: "work.failed"
      )

    assert :ok = run_directive(agent, directive)

    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.failed"
    assert signal.data == %{kind: :throw, reason: :thrown_value}
  end

  test("converts exits into error signals", %{agent: agent}) do
    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :exit_value, []},
        error_type: "work.failed"
      )

    assert :ok = run_directive(agent, directive)

    assert_receive {:aikido_subscription, _, %{result: {:ok, signal}}}, 1000
    assert signal.type == "work.failed"
    assert signal.data == %{kind: :exit, reason: :exited_value}
  end

  test("does not crash when the reply target is unavailable", %{agent: agent}) do
    test_pid = self()

    directive =
      Aikido.Directives.async_task({Aikido.Directives.AsyncTaskTest.Work, :ok, [test_pid]},
        success_type: "work.completed",
        target: :missing_async_task_target
      )

    assert :ok = run_directive(agent, directive)

    assert_receive :ok_work_ran, 1000
    refute_receive {:aikido_subscription, _, _}, 100
  end
end
