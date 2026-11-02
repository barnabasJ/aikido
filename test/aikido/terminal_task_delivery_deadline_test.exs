defmodule Aikido.TerminalTaskDeliveryDeadlineTest.Client do
  @moduledoc false

  def generate_text(_model, messages, options) do
    response = %ReqLLM.Response{
      id: "terminal-task-result",
      model: "offline",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant("Received the terminal task result.", tool_calls: []),
      finish_reason: :stop
    }

    case options[:observer] do
      nil ->
        {:ok, response}

      observer ->
        monitor = Process.monitor(observer)
        send(observer, {:terminal_task_model, self(), messages})

        try do
          receive do
            :finish_terminal_task_model -> {:ok, response}
            {:DOWN, ^monitor, :process, ^observer, _} -> {:error, :test_observer_stopped}
          after
            10_000 -> {:error, :test_model_gate_timeout}
          end
        after
          Process.demonitor(monitor, [:flush])
        end
    end
  end
end

defmodule Aikido.TerminalTaskDeliveryDeadlineTest.Worker do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.TerminalTaskDeliveryDeadlineTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "terminal_deadline_worker"
    instance Aikido.TerminalTaskDeliveryDeadlineTest.Instance
  end

  ai do
    model "offline"
    client Aikido.TerminalTaskDeliveryDeadlineTest.Client
    options %{model_max_retries: 0}
  end
end

defmodule Aikido.TerminalTaskDeliveryDeadlineTest.Team do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.TerminalTaskDeliveryDeadlineTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension, Aikido.AI.Extension]

  agent do
    name "terminal_deadline_team"
    instance Aikido.TerminalTaskDeliveryDeadlineTest.Instance
  end

  ai do
    model "offline"
    client Aikido.TerminalTaskDeliveryDeadlineTest.Client
    options %{model_max_retries: 0}
  end

  team do
    member :worker, Aikido.TerminalTaskDeliveryDeadlineTest.Worker, activation: :lazy
  end
end

defmodule Aikido.TerminalTaskDeliveryDeadlineTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :terminal, Aikido.TerminalTaskDeliveryDeadlineTest.Team
    agent :worker, Aikido.TerminalTaskDeliveryDeadlineTest.Worker
  end
end

defmodule Aikido.TerminalTaskDeliveryDeadlineTest do
  use ExUnit.Case, async: true
  import AikidoTest.Case, only: [unique_id: 1]

  alias Aikido.TerminalTaskDeliveryDeadlineTest.Domain

  setup context do
    if context[:native_runtime] do
      instance = Aikido.TerminalTaskDeliveryDeadlineTest.Instance

      runtime =
        start_supervised!({Aikido, name: instance, durable: AikidoTest.Case.durable_options()})

      register_join(runtime)
      attempts = Process.whereis(Aikido.task_supervisor_name(instance))
      assert is_pid(attempts)
      register_join(attempts)
      %{instance: instance, runtime: runtime, attempts: attempts}
    else
      :ok
    end
  end

  for status <- [:completed, :failed] do
    test "#{status} terminal metadata retains history without a receiver deadline" do
      task = %{
        id: "terminal-task",
        member: :worker,
        status: unquote(status),
        result: if(unquote(status) == :completed, do: "done", else: :timeout),
        metadata: %{aikido_deadline_at: 1, workflow_step_id: "historical-step"}
      }

      signal = Aikido.Team.TaskDelivery.conversation_message_for_task_result(task)
      assert signal.data.request_id == "task-result/terminal-task"
      assert signal.data.metadata == %{task: task}
      refute Map.has_key?(signal.data.metadata, :aikido_deadline_at)
      assert signal.data.metadata.task.metadata == task.metadata
      assert signal.data.metadata.task.result == task.result
    end
  end

  @tag :native_runtime
  @tag :terminal_task_deadline_regression
  test "an idle parent consumes a real expired worker result without adopting its expired deadline",
       ctx do
    assert_runtime_retires(ctx, fn ->
      parent =
        Domain.terminal_start!(%{
          id: unique_id("terminal-deadline"),
          llm_opts: [observer: self()]
        })

      parent_down = register_join(parent.pid)
      Domain.terminal_ensure_member!(parent, %{member: :worker})
      worker = Domain.terminal_inspect!(parent).team.members.worker
      worker_down = register_join(worker)
      assert Domain.terminal_inspect!(parent).ai.status == :idle

      {:ok, terminal} =
        Aikido.AgentServer.subscribe(
          parent.pid,
          "**",
          fn runtime ->
            ai = runtime.agent.state.ai

            if ai.request_id == "task-result/expired-worker" && ai.status in [:completed, :failed],
              do: {:ok, runtime.agent.state},
              else: :skip
          end,
          once: true
        )

      expired = System.system_time(:millisecond) - 10_000

      Domain.terminal_assign_task!(parent, %{
        member: :worker,
        task_id: "expired-worker",
        mode: :background,
        notify: :self,
        metadata: %{aikido_deadline_at: expired, workflow_step_id: "actual-expired-worker"},
        payload: %{text: "An already-expired assignment must fail before a model call."}
      })

      opening =
        receive do
          {:terminal_task_model, model, messages} -> {:model, model, messages}
          {:aikido_subscription, ^terminal, %{result: {:ok, state}}} -> {:settled, state}
        after
          5_000 -> flunk("The actual receiver neither requested a model nor settled its run.")
        end

      assert {:model, model, messages} = opening
      model_down = register_join(model)
      send(model, :finish_terminal_task_model)
      assert_receive {:aikido_subscription, ^terminal, %{result: {:ok, state}}}, 5_000
      assert state.team.tasks["expired-worker"].status == :failed
      assert state.team.tasks["expired-worker"].result == :timeout
      assert state.ai.status == :completed
      assert state.ai.error == nil
      assert state.ai.deadline_at == nil
      assert state.ai.run_metadata.task.metadata.aikido_deadline_at == expired
      refute Map.has_key?(state.ai.run_metadata, :aikido_deadline_at)

      text = messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", &(&1.text || ""))
      assert text =~ "Task expired-worker from worker failed"
      assert text =~ "remaining deadline expired"
      assert_receive {:DOWN, ^model_down, :process, ^model, _}, 5_000

      assert {:ok, _receipt} = Domain.terminal_stop(parent)
      assert_receive {:DOWN, ^parent_down, :process, _, _}, 5_000
      assert_receive {:DOWN, ^worker_down, :process, ^worker, _}, 5_000
    end)
  end

  @tag :native_runtime
  @tag :completed_terminal_deadline
  test "a completed child result can open an idle continuation after its historical deadline",
       ctx do
    assert_runtime_retires(ctx, fn ->
      observer = self()

      parent =
        Domain.terminal_start!(%{
          id: unique_id("completed-result"),
          llm_opts: [observer: observer]
        })

      register_join(parent.pid)
      Domain.terminal_ensure_member!(parent, %{member: :worker})
      worker = Domain.terminal_inspect!(parent).team.members.worker
      register_join(worker)
      deadline = System.system_time(:millisecond) + 2_000
      task_id = "completed-before-expiry"
      nonce = make_ref()

      {:ok, terminal} =
        Aikido.AgentServer.subscribe(
          parent.pid,
          "**",
          fn runtime ->
            ai = runtime.agent.state.ai

            if ai.request_id == "task-result/" <> task_id and ai.status in [:completed, :failed],
              do: {:ok, runtime.agent.state},
              else: :skip
          end,
          once: true
        )

      Domain.terminal_assign_task!(parent, %{
        member: :worker,
        task_id: task_id,
        notify: :self,
        metadata: %{aikido_deadline_at: deadline},
        payload: %{
          text: "Finish before the historical task budget",
          llm_opts: [observer: observer]
        }
      })

      assert_receive {:terminal_task_model, worker_model, _messages}, 5_000
      register_join(worker_model)

      read =
        Task.Supervisor.async_nolink(ctx.attempts, fn ->
          Aikido.AgentServer.state(
            parent.pid,
            fn _runtime ->
              monitor = Process.monitor(observer)
              delay = max(deadline - System.system_time(:millisecond) + 100, 0)
              timer = Process.send_after(self(), {nonce, :release}, delay)
              send(observer, {nonce, :parent_read_held, self()})

              try do
                receive do
                  {^nonce, :release} -> {:ok, :released}
                  {:DOWN, ^monitor, :process, ^observer, _reason} -> {:ok, :owner_stopped}
                after
                  4_000 -> {:error, :test_read_gate_timeout}
                end
              after
                Process.cancel_timer(timer)
                Process.demonitor(monitor, [:flush])
              end
            end,
            timeout: 5_000
          )
        end)

      register_join(read.pid)
      assert_receive {^nonce, :parent_read_held, parent_pid}, 5_000
      assert parent_pid == parent.pid

      assert {:ok, :completed} =
               Aikido.AgentServer.call_until(
                 worker,
                 fn ->
                   send(worker_model, :finish_terminal_task_model)
                   :ok
                 end,
                 "**",
                 fn runtime ->
                   if runtime.agent.state.ai.status == :completed,
                     do: {:ok, :completed},
                     else: :skip
                 end,
                 timeout: 1_500
               )

      assert System.system_time(:millisecond) < deadline
      assert {:ok, :released} = Task.await(read, 5_000)
      assert System.system_time(:millisecond) > deadline

      opening =
        receive do
          {:terminal_task_model, model, messages} -> {:model, model, messages}
          {:aikido_subscription, ^terminal, %{result: {:ok, state}}} -> {:settled, state}
        after
          5_000 -> flunk("The actual completed result neither opened a model nor settled.")
        end

      assert {:model, model, _messages} = opening
      register_join(model)
      send(model, :finish_terminal_task_model)
      assert_receive {:aikido_subscription, ^terminal, %{result: {:ok, state}}}, 5_000
      assert state.team.tasks[task_id].status == :completed
      assert state.ai.status == :completed
      assert state.ai.deadline_at == nil
      assert state.ai.run_metadata.task.metadata.aikido_deadline_at == deadline
    end)
  end

  @tag :native_runtime
  @tag :active_terminal_deadline
  test "a child result preserves an active parent's original request and deadline", ctx do
    assert_runtime_retires(ctx, fn ->
      parent =
        Domain.terminal_start!(%{id: unique_id("active-result"), llm_opts: [observer: self()]})

      register_join(parent.pid)
      Domain.terminal_ensure_member!(parent, %{member: :worker})
      register_join(Domain.terminal_inspect!(parent).team.members.worker)
      deadline = System.system_time(:millisecond) + 2_000

      {:ok, terminal} =
        Aikido.AgentServer.subscribe(
          parent.pid,
          "**",
          fn runtime ->
            ai = runtime.agent.state.ai
            if ai.status == :failed, do: {:ok, ai}, else: :skip
          end,
          once: true
        )

      assert {:ok, request} =
               Aikido.AI.ask(parent.pid, "Keep this original run open",
                 metadata: %{aikido_deadline_at: deadline}
               )

      assert_receive {:terminal_task_model, original_model, _messages}, 5_000
      original_down = register_join(original_model)

      {:ok, delivered} =
        Aikido.AgentServer.subscribe(
          parent.pid,
          "ai.react.deliver",
          fn runtime ->
            {:ok, runtime.agent.state.ai}
          end,
          once: true
        )

      Domain.terminal_assign_task!(parent, %{
        member: :worker,
        task_id: "active-parent-child",
        notify: :self,
        metadata: %{aikido_deadline_at: deadline + 10_000},
        payload: %{text: "Return while the parent model is held"}
      })

      assert_receive {:aikido_subscription, ^delivered, %{result: {:ok, active}}}, 5_000
      assert active.status == :running
      assert active.request_id == request
      assert active.deadline_at == deadline
      assert_receive {:aikido_subscription, ^terminal, %{result: {:ok, failed}}}, 5_000
      assert failed.request_id == request
      assert failed.deadline_at == deadline
      assert failed.error == :timeout
      assert_receive {:DOWN, ^original_down, :process, ^original_model, _reason}, 5_000
    end)
  end

  @tag :native_runtime
  @tag :explicit_new_run_deadline
  test "an explicit deadline on an ordinary new delivery is still honored", ctx do
    assert_runtime_retires(ctx, fn ->
      parent =
        Domain.terminal_start!(%{
          id: unique_id("explicit-delivery"),
          llm_opts: [observer: self()]
        })

      register_join(parent.pid)
      expired = System.system_time(:millisecond) - 1

      {:ok, terminal} =
        Aikido.AgentServer.subscribe(
          parent.pid,
          "**",
          fn runtime ->
            ai = runtime.agent.state.ai

            if ai.request_id == "explicit-new-run" and ai.status in [:completed, :failed],
              do: {:ok, ai},
              else: :skip
          end,
          once: true
        )

      assert {:ok, _receipt} =
               Domain.terminal_deliver(parent, %{
                 text: "This is an explicit new-run deadline, not terminal child history",
                 request_id: "explicit-new-run",
                 metadata: %{aikido_deadline_at: expired}
               })

      assert_receive {:aikido_subscription, ^terminal, %{result: {:ok, failed}}}, 5_000
      assert failed.status == :failed
      assert failed.error == :timeout
      assert failed.deadline_at == expired
      refute_received {:terminal_task_model, _model, _messages}
    end)
  end

  defp assert_runtime_retires(ctx, assertions) do
    errors = collect_failure(assertions)

    errors =
      errors ++
        Enum.flat_map(
          [
            fn -> assert :ok = stop_supervised(ctx.instance) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(ctx.runtime, 10_000) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(ctx.attempts, 10_000) end
          ],
          &collect_failure/1
        )

    report_failures(errors)
  end

  defp register_join(pid) do
    on_exit(fn -> assert :ok = AikidoTest.LifecycleWait.await_down(pid, 10_000) end)
    Process.monitor(pid)
  end

  defp collect_failure(operation) do
    operation.()
    []
  catch
    :error, %ExUnit.MultiError{errors: errors} -> errors
    kind, reason -> [{kind, reason, __STACKTRACE__}]
  end

  defp report_failures([]), do: :ok
  defp report_failures([{kind, reason, stacktrace}]), do: :erlang.raise(kind, reason, stacktrace)
  defp report_failures(errors), do: raise(ExUnit.MultiError, errors: errors)
end
