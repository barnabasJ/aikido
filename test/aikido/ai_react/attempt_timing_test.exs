defmodule Aikido.AttemptTimingTest.Begin do
  use Aikido.Signal

  signal do
    type "ai.react.clock.begin"

    schema do
      attribute :request_id, :string do
        description "Correlation of the actual routed run."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.AttemptTimingTest.BeginRun do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    Aikido.Types.ActionResult.new(
      changes: %{status: :running, request_id: input.arguments.request_id}
    )
  end
end

defmodule Aikido.AttemptTimingTest.Owner do
  use Aikido.Agent

  agent do
    name "attempt_clock_owner"
    path :ai

    schema do
      attribute :request_id, :string do
        description "Actual live run identity observed by native cancellation."
      end

      attribute :status, Aikido.AiReact.Types.Status do
        description "Actual run status changed through a routed native action."
        default :idle
        allow_nil? false
      end
    end

    route Aikido.AttemptTimingTest.Begin, Aikido.AttemptTimingTest.BeginRun
  end
end

defmodule Aikido.AttemptTimingTest do
  use AikidoTest.Case, async: true
  alias Aikido.AttemptTimingTest.Manual
  alias Aikido.AiReact.CancellableTask

  setup context do
    owner = start_server(context, Aikido.AttemptTimingTest.Owner)
    signal = Aikido.AttemptTimingTest.Begin.new!(%{request_id: "clock-run"})
    assert {:ok, :started} = Aikido.AgentServer.call(owner, signal, fn _ -> {:ok, :started} end)
    clock = start_supervised!({Manual, self()})
    %{owner: owner, clock: clock, supervisor: Aikido.task_supervisor_name(context.aikido)}
  end

  test "real progress permits a stream lasting longer than the progress window", ctx do
    observer = self()

    work = fn notify, _attempt ->
      send(observer, {:work_started, self()})
      chunks(notify, [])
    end

    task = attempt(ctx, work, timeout: 1_000, progress_timeout: 150)
    caller = task.pid
    assert_receive {:work_started, worker}, 5_000
    assert_receive {:armed, ^caller, _tag, 150}, 5_000

    for number <- 1..8 do
      :ok = Manual.advance(ctx.clock, number * 30)
      send(worker, {:chunk, "#{number}"})
      expected = number * 30 + 150
      assert_receive {:armed, ^caller, _tag, ^expected}, 5_000
    end

    send(worker, :finish)
    assert {:ok, "12345678"} = Task.await(task, 5_000)
    assert Manual.monotonic_ms(ctx.clock) == 240
  end

  test "attempt deadline stays fixed across progress and stale retired timer tags", ctx do
    observer = self()

    task =
      attempt(
        ctx,
        fn notify, _ ->
          send(observer, {:work_started, self()})
          chunks(notify, [])
        end,
        timeout: 80,
        progress_timeout: 150
      )

    caller = task.pid
    assert_receive {:work_started, worker}, 5_000
    ref = Process.monitor(worker)
    assert_receive {:armed, ^caller, old_tag, 80}, 5_000
    :ok = Manual.advance(ctx.clock, 30)
    send(worker, {:chunk, "one"})
    assert_receive {:armed, ^caller, new_tag, 80}, 5_000
    refute old_tag == new_tag
    send(caller, old_tag)
    :ok = Manual.advance(ctx.clock, 80)
    assert {:error, :timeout} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000
  end

  test "retry backoff advances only on its virtual timer", ctx do
    observer = self()

    task =
      attempt(
        ctx,
        fn _notify, number ->
          send(observer, {:attempt_started, number})
          if number == 0, do: {:error, :timeout}, else: {:ok, :retried}
        end,
        timeout: 80,
        progress_timeout: 80,
        retries: 1,
        backoff: 20
      )

    caller = task.pid
    assert_receive {:attempt_started, 0}, 5_000
    assert_receive {:armed, ^caller, {_reference, :aikido_attempt_backoff}, 20}, 5_000
    refute_received {:attempt_started, 1}
    :ok = Manual.advance(ctx.clock, 20)
    assert_receive {:attempt_started, 1}, 5_000
    assert {:ok, :retried} = Task.await(task, 5_000)
  end

  test "inherited absolute deadline also bounds virtual retry backoff", ctx do
    observer = self()

    task =
      attempt(
        ctx,
        fn _notify, number ->
          send(observer, {:absolute_attempt, number})
          {:error, :timeout}
        end,
        timeout: 80,
        progress_timeout: 80,
        retries: 1,
        backoff: 20,
        deadline_at: Manual.system_ms(ctx.clock) + 10
      )

    caller = task.pid
    assert_receive {:absolute_attempt, 0}, 5_000
    assert_receive {:armed, ^caller, {_reference, :aikido_attempt_backoff}, 10}, 5_000
    :ok = Manual.advance(ctx.clock, 10)
    assert {:error, :timeout} = Task.await(task, 5_000)
    refute_received {:absolute_attempt, 1}
  end

  defp chunks(notify, received) do
    receive do
      {:chunk, text} ->
        notify.(:progress)
        chunks(notify, [text | received])

      :finish ->
        {:ok, received |> Enum.reverse() |> Enum.join()}
    end
  end

  defp attempt(ctx, work, options) do
    options = Keyword.put(options, :timing, {Manual, ctx.clock})

    Task.async(fn ->
      CancellableTask.run_cancellable_attempts(
        ctx.owner,
        "clock-run",
        ctx.supervisor,
        work,
        options
      )
    end)
  end
end
