defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Signals.StartAttempt do
  use Aikido.Signal

  signal do
    type "test.subscribe_budget.start"

    schema do
      attribute :request_id, :string do
        description "Attempt correlation the cancellable task selector matches."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Actions.StartAttempt do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{status: :running, request_id: input.arguments.request_id}
    )
  end
end

defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Agent do
  use Aikido.Agent

  agent do
    name "cancellable_subscribe_budget_scenario"
    path :ai
    persistence :temporary

    schema do
      attribute :request_id, :string do
        description "Attempt correlation of the currently executing slice."
      end

      attribute :status, Aikido.AiReact.Types.Status do
        description "Whether the attempt slice is running or has returned."
        default :idle
        allow_nil? false
      end
    end

    route Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Signals.StartAttempt,
          Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Actions.StartAttempt
  end
end

defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest do
  @moduledoc """
  Uses an actual suspended owner and observed queued registration to exercise
  subscription budgets independently of host throughput. This file covers registration.
  Shared state-read budgets are covered in `cancellable_task_preflight_contract_test.exs`.
  """
  use AikidoTest.Case, async: true

  alias Aikido.AiReact.CancellableTask

  @request_id "subscribe-budget-req"
  @attempt_budget 30_000
  @beyond_default_ms 6_000

  setup %{aikido: instance, aikido_pid: runtime} do
    supervisor = start_supervised!(Task.Supervisor)
    native_tasks = Process.whereis(Aikido.task_supervisor_name(instance))
    register_join(supervisor)
    register_join(runtime)
    assert is_pid(native_tasks)
    register_join(native_tasks)
    %{supervisor: supervisor, native_tasks: native_tasks}
  end

  @tag :subscribe_budget_success
  test "a queued attempt registration waits beyond the default within its remaining budget",
       context do
    token = make_ref()
    observer = self()

    call = fn owner ->
      CancellableTask.run_cancellable_attempts(
        owner,
        @request_id,
        context.supervisor,
        fn _notify, _attempt ->
          monitor = Process.monitor(observer)
          send(observer, {:subscribe_budget_work_started, token, self()})

          try do
            receive do
              {:finish_subscribe_budget_work, ^token} -> {:ok, :work_completed}
              {:DOWN, ^monitor, :process, ^observer, _} -> {:error, :test_observer_stopped}
            after
              10_000 -> {:error, :test_work_gate_timeout}
            end
          after
            Process.demonitor(monitor, [:flush])
          end
        end,
        timeout: @attempt_budget,
        deadline_at: System.system_time(:millisecond) + @attempt_budget,
        retries: 0
      )
    end

    assert_held_registration_retires(context, token, call, fn owner, caller ->
      send(caller.pid, {:start_subscribe_budget_call, token})
      assert_queued_registration(owner, caller.pid)
      reference = caller.ref

      # Registration is already queued and the real owner is still suspended.
      # The elapsed interval, rather than host work throughput, is the contract.
      refute_receive {^reference, _early_result}, @beyond_default_ms
      refute_received {:subscribe_budget_work_started, ^token, _}
      assert :ok = :sys.resume(owner)

      assert_receive {:subscribe_budget_work_started, ^token, work}, 5_000
      work_down = register_join(work)
      send(work, {:finish_subscribe_budget_work, token})
      assert {:ok, :work_completed} = Task.await(caller, 5_000)
      assert_receive {:DOWN, ^work_down, :process, ^work, _}, 5_000
      assert Process.alive?(owner)
    end)
  end

  @tag :subscribe_budget_default
  test "a held registration without a budget retains the five-second default", context do
    token = make_ref()

    call = fn owner ->
      try do
        {:returned,
         Aikido.AgentServer.subscribe(owner, "ai.react.**", fn _ -> {:ok, :never} end, once: true)}
      catch
        :exit, reason -> {:exit, reason}
      end
    end

    assert_held_registration_retires(context, token, call, fn owner, caller ->
      send(caller.pid, {:start_subscribe_budget_call, token})
      assert_queued_registration(owner, caller.pid)

      assert {:exit,
              {:timeout, {GenServer, :call, [^owner, {:subscribe, _, _, _, _, _, _}, 5_000]}}} =
               Task.await(caller, 8_000)
    end)
  end

  @tag :subscribe_budget_explicit
  test "an explicit registration timeout expires while the actual owner stays held", context do
    token = make_ref()

    call = fn owner ->
      try do
        {:returned,
         Aikido.AgentServer.subscribe(owner, "ai.react.**", fn _ -> {:ok, :never} end,
           once: true,
           timeout: 200
         )}
      catch
        :exit, reason -> {:exit, reason}
      end
    end

    assert_held_registration_retires(context, token, call, fn owner, caller ->
      send(caller.pid, {:start_subscribe_budget_call, token})
      assert_queued_registration(owner, caller.pid)

      assert {:exit,
              {:timeout, {GenServer, :call, [^owner, {:subscribe, _, _, _, _, _, _}, 200]}}} =
               Task.await(caller, 5_000)
    end)
  end

  @tag :subscribe_budget_expired
  test "an exhausted pre-open budget returns timeout without sending a registration", context do
    token = make_ref()
    observer = self()

    call = fn owner ->
      CancellableTask.run_cancellable_attempts(
        owner,
        @request_id,
        context.supervisor,
        fn _notify, _attempt ->
          send(observer, {:subscribe_budget_work_started, token, self()})
          {:ok, :unexpected_work}
        end,
        timeout: @attempt_budget,
        deadline_at: System.system_time(:millisecond) - 1,
        retries: 0
      )
    end

    assert_held_registration_retires(context, token, call, fn owner, caller ->
      caller_pid = caller.pid
      assert 1 = :erlang.trace(caller_pid, true, [:send, {:tracer, self()}])
      send(caller_pid, {:start_subscribe_budget_call, token})
      result = Task.await(caller, 8_000)

      # OTP's delivery barrier includes all prior send traces, even after exit.
      delivered = :erlang.trace_delivered(caller_pid)
      assert_receive {:trace_delivered, ^caller_pid, ^delivered}, 5_000

      refute_received {:trace, ^caller_pid, :send,
                       {:"$gen_call", _, {:subscribe, _, _, _, _, _, _}}, ^owner}

      refute_received {:subscribe_budget_work_started, ^token, _}
      assert result == {:error, :timeout}
    end)
  end

  defp assert_held_registration_retires(context, token, call, assertions) do
    owner = start_server(context, __MODULE__.Agent)
    owner_down = register_join(owner)

    caller =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        receive do
          {:start_subscribe_budget_call, ^token} -> call.(owner)
        after
          10_000 -> {:error, :test_call_start_timeout}
        end
      end)

    caller_down = register_join(caller.pid)

    errors =
      collect_failure(fn ->
        start_running_slice(owner, @request_id)
        assert :ok = :sys.suspend(owner)
        assert 1 = :erlang.trace(owner, true, [:receive, {:tracer, self()}])
        assertions.(owner, caller)
      end)

    errors =
      errors ++
        Enum.flat_map(
          [
            fn ->
              if Process.alive?(owner) do
                :erlang.trace(owner, false, [:receive])
                assert :ok = :sys.resume(owner)
              end
            end,
            fn -> assert :ok = stop_supervised(Task.Supervisor) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(caller.pid, 10_000) end,
            fn ->
              assert :ok = AikidoTest.LifecycleWait.await_down(context.supervisor, 10_000)
            end,
            fn -> assert :ok = stop_supervised(context.aikido) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(owner, 10_000) end,
            fn ->
              assert :ok = AikidoTest.LifecycleWait.await_down(context.aikido_pid, 10_000)
            end,
            fn ->
              assert :ok = AikidoTest.LifecycleWait.await_down(context.native_tasks, 10_000)
            end
          ],
          &collect_failure/1
        )

    # These refs were installed before the assertions or test-owned stop actions.
    errors =
      errors ++
        collect_failure(fn ->
          assert_receive {:DOWN, ^caller_down, :process, _, _}, 5_000
          assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 5_000
        end)

    report_failures(errors)
  end

  defp assert_queued_registration(owner, caller) do
    assert_receive {:trace, ^owner, :receive,
                    {:"$gen_call", _,
                     {:subscribe, "ai.react.**", _, ^caller, ^caller, true, true}}},
                   5_000
  end

  defp start_running_slice(owner, request_id) do
    start = Aikido.Signal.new!("test.subscribe_budget.start", %{request_id: request_id})

    assert {:ok, :running} =
             Aikido.AgentServer.call(owner, start, fn runtime ->
               {:ok, runtime.agent.state.ai.status}
             end)
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
