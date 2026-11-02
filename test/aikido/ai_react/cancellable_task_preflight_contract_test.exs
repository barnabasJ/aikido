defmodule Aikido.CancellableTaskPreflightContractTest.Signals.BeginRun do
  use Aikido.Signal

  signal do
    type "test.preflight.begin"

    schema do
      attribute :request_id, :string do
        description "Actual run correlation matched by the cancellable attempt."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.CancellableTaskPreflightContractTest.Actions.BeginRun do
  use Ash.Resource.Actions.Implementation

  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{request_id: input.arguments.request_id, status: :running}
    )
  end
end

defmodule Aikido.CancellableTaskPreflightContractTest.Agent do
  use Aikido.Agent

  agent do
    name "preflight_contract"
    path :ai
    persistence :temporary

    schema do
      attribute :request_id, :string do
        description "Current real run identity."
      end

      attribute :status, Aikido.AiReact.Types.Status do
        description "Current run status observed by the real subscription."
        default :idle
        allow_nil? false
      end
    end

    route Aikido.CancellableTaskPreflightContractTest.Signals.BeginRun,
          Aikido.CancellableTaskPreflightContractTest.Actions.BeginRun
  end
end

defmodule Aikido.CancellableTaskPreflightContractTest do
  @moduledoc "Live AgentServer preflight budgets and independent per-attempt retry windows."
  use AikidoTest.Case, async: true

  alias Aikido.AiReact.CancellableTask
  alias AikidoTest.AgentServerPreflightGate, as: Gate

  @request "preflight-live-run"

  @tag :preflight_short_deadline
  test "a short absolute budget bounds the post-subscribe read without starting work", context do
    with_attempt(context, :state, 1_600, 500, fn owner, caller, nonce ->
      assert_receive {^nonce, :registered, ^owner, _reference}, 5_000
      assert_receive {^nonce, :held, ^owner, :state}, 5_000
      assert_receive {:attempt_result, ^nonce, result, elapsed}, 5_000
      assert result == {:error, :timeout}
      assert elapsed < 1_200
      refute_received {:work_started, ^nonce, _work}
      assert Process.alive?(owner)
      assert Process.alive?(caller.pid)
    end)
  end

  @tag :preflight_long_deadline
  test "a valid long budget survives a state read held beyond the hidden five seconds", context do
    with_attempt(context, :state, 6_000, 20_000, fn owner, caller, nonce ->
      assert_receive {^nonce, :registered, ^owner, _reference}, 5_000
      assert_receive {^nonce, :held, ^owner, :state}, 5_000
      assert_receive {:attempt_result, ^nonce, result, _elapsed}, 9_000
      assert result == {:ok, :work_completed}
      assert_receive {^nonce, :released, ^owner, elapsed}, 5_000
      assert elapsed >= 5_000
      assert_receive {:work_started, ^nonce, work}, 5_000
      assert :ok = AikidoTest.LifecycleWait.await_down(work, 5_000)
      assert Process.alive?(caller.pid)
    end)
  end

  @tag :preflight_relative_shared
  test "relative preflight shares one window across registration and state read", context do
    with_attempt(
      context,
      :both,
      400,
      600,
      fn owner, caller, nonce ->
        assert_receive {^nonce, :held, ^owner, :subscribe}, 5_000
        assert_receive {^nonce, :registered, ^owner, _reference}, 5_000
        assert_receive {^nonce, :held, ^owner, :state}, 5_000
        assert_receive {:attempt_result, ^nonce, result, elapsed}, 5_000
        assert result == {:error, :timeout}
        assert elapsed < 1_200
        refute_received {:work_started, ^nonce, _work}
        assert Process.alive?(caller.pid)
      end,
      absolute?: false
    )
  end

  @tag :relative_retry_windows
  test "relative retry work windows outlive the completed preflight ceiling", context do
    work = fn observer, nonce, attempt ->
      monitor = Process.monitor(observer)
      send(observer, {nonce, :retry_attempt, attempt, self()})

      try do
        receive do
          {^nonce, :monitored} ->
            timer = Process.send_after(self(), {nonce, :work_finished}, 800)

            try do
              receive do
                {^nonce, :work_finished} ->
                  if attempt == 0, do: {:error, :timeout}, else: {:ok, :work_completed}

                {:DOWN, ^monitor, :process, ^observer, _reason} ->
                  {:error, :test_owner_stopped}
              after
                2_000 -> {:error, :test_work_gate_timeout}
              end
            after
              Process.cancel_timer(timer)
            end

          {:DOWN, ^monitor, :process, ^observer, _reason} ->
            {:error, :test_owner_stopped}
        after
          2_000 -> {:error, :test_monitor_gate_timeout}
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    with_attempt(
      context,
      :state,
      200,
      1_200,
      fn owner, caller, nonce ->
        assert_receive {^nonce, :registered, ^owner, _reference}, 5_000
        assert_receive {^nonce, :held, ^owner, :state}, 5_000
        assert_receive {^nonce, :retry_attempt, 0, first}, 5_000
        first_down = Process.monitor(first)
        send(first, {nonce, :monitored})
        assert_receive {^nonce, :retry_attempt, 1, second}, 5_000
        second_down = Process.monitor(second)
        send(second, {nonce, :monitored})
        assert_receive {:attempt_result, ^nonce, result, elapsed}, 5_000
        assert result == {:ok, :work_completed}
        assert elapsed > 1_200
        assert_receive {:DOWN, ^first_down, :process, ^first, _first_reason}, 5_000
        assert_receive {:DOWN, ^second_down, :process, ^second, _second_reason}, 5_000
        assert Process.alive?(caller.pid)
      end,
      absolute?: false,
      retries: 1,
      work: work
    )
  end

  defp with_attempt(context, phase, hold_ms, budget, assertions, test_options \\ []) do
    owner = start_server(context, __MODULE__.Agent)
    owner_down = Process.monitor(owner)
    supervisor = start_supervised!(Task.Supervisor)
    supervisor_down = Process.monitor(supervisor)
    observer = self()

    assert {:ok, :ready} =
             Aikido.AgentServer.call(
               owner,
               __MODULE__.Signals.BeginRun.new!(%{request_id: @request}),
               fn _ -> {:ok, :ready} end
             )

    caller =
      Task.Supervisor.async_nolink(supervisor, fn ->
        monitor = Process.monitor(observer)

        try do
          receive do
            {:start, nonce} ->
              started = System.monotonic_time(:millisecond)

              options = [
                timeout: budget,
                retries: Keyword.get(test_options, :retries, 0),
                backoff: 10
              ]

              options =
                if Keyword.get(test_options, :absolute?, true),
                  do:
                    Keyword.put(options, :deadline_at, System.system_time(:millisecond) + budget),
                  else: options

              work =
                Keyword.get(test_options, :work, fn observer, nonce, _attempt ->
                  send(observer, {:work_started, nonce, self()})
                  {:ok, :work_completed}
                end)

              result =
                CancellableTask.run_cancellable_attempts(
                  owner,
                  @request,
                  supervisor,
                  fn _notify, attempt -> work.(observer, nonce, attempt) end,
                  options
                )

              send(observer, {
                :attempt_result,
                nonce,
                result,
                System.monotonic_time(:millisecond) - started
              })

              receive do
                {:finish, ^nonce} -> result
                {:DOWN, ^monitor, :process, ^observer, _reason} -> result
              after
                20_000 -> {:error, :test_caller_release_timeout}
              end
          after
            5_000 -> {:error, :test_start_timeout}
          end
        after
          Process.demonitor(monitor, [:flush])
        end
      end)

    caller_down = Process.monitor(caller.pid)
    nonce = Gate.install(owner, caller.pid, phase, hold_ms)
    send(caller.pid, {:start, nonce})
    errors = capture_failure(fn -> assertions.(owner, caller, nonce) end)

    errors =
      errors ++
        Enum.flat_map(
          [
            fn -> Gate.release(owner, nonce) end,
            fn ->
              send(caller.pid, {:finish, nonce})
              Task.await(caller, 10_000)
            end,
            fn -> :sys.remove(owner, nonce) end,
            fn -> Aikido.Durable.stop(Aikido.durable_supervisor_name(context.aikido), owner) end,
            fn -> assert_receive {:DOWN, ^caller_down, :process, _, _}, 5_000 end,
            fn -> assert_receive {:DOWN, ^owner_down, :process, _, _}, 5_000 end,
            fn -> assert :ok = stop_supervised(Task.Supervisor) end,
            fn -> assert_receive {:DOWN, ^supervisor_down, :process, _, _}, 5_000 end
          ],
          &capture_failure/1
        )

    report_failures(errors)
  end

  defp capture_failure(operation) do
    operation.()
    []
  catch
    kind, reason -> [{kind, reason, __STACKTRACE__}]
  end

  defp report_failures([]), do: :ok
  defp report_failures([{kind, reason, stack}]), do: :erlang.raise(kind, reason, stack)
  defp report_failures(errors), do: raise(ExUnit.MultiError, errors: errors)
end
