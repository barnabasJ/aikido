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

defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Signals.Flood do
  use Aikido.Signal

  signal do
    type "test.subscribe_budget.flood"

    schema do
      attribute :n, :integer do
        description "Padding that keeps each flooded envelope non-trivial."
        allow_nil? true
      end
    end
  end
end

defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Actions.AbsorbFlood do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _, _) do
    Aikido.Types.ActionResult.new(changes: nil)
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

    route Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Signals.Flood,
          Aikido.AiReact.CancellableTaskSubscribeBudgetTest.Actions.AbsorbFlood
  end
end

defmodule Aikido.AiReact.CancellableTaskSubscribeBudgetTest do
  @moduledoc """
  The cancellable attempt's subscribe handshake consumes the attempt's
  remaining tool deadline, not the 5 s default call budget.

  Every attempt opens with a synchronous
  `Aikido.AgentServer.subscribe(owner, "ai.react.**", selector, once: true)`
  into the streaming agent's mailbox. A saturated owner mailbox queues that
  registration behind the flood, so the 5 s default call budget could consume
  the whole attempt before the tool's own budget ran (`owner_unavailable`
  timeouts observed live). The handshake now carries the attempt's remaining
  deadline, while callers that give no budget keep the 5 s default.
  """
  use AikidoTest.Case, async: false

  alias Aikido.AiReact.CancellableTask

  # Sized so the flooded mailbox drains slower than the 5 s default call
  # budget (verified on the QA baseline), leaving the handshake queued when
  # the default expires but well inside the attempt's own deadline.
  @flood_signals 150_000

  @request_id "subscribe-budget-req"
  @attempt_budget 30_000

  setup do
    supervisor_name =
      :"cancellable_subscribe_budget_sup_#{System.unique_integer([:positive])}"

    start_supervised!({Task.Supervisor, name: supervisor_name})

    %{supervisor: supervisor_name}
  end

  test "a busy owner lets the subscribe handshake wait out the attempt's remaining deadline",
       %{supervisor: supervisor} = context do
    owner = start_server(context, __MODULE__.Agent)
    start_running_slice(owner, @request_id)
    flood_agent(owner)

    result =
      CancellableTask.run_cancellable_attempts(
        owner,
        @request_id,
        supervisor,
        fn _notify, _attempt -> {:ok, :work_completed} end,
        timeout: @attempt_budget,
        deadline_at: System.system_time(:millisecond) + @attempt_budget,
        retries: 0
      )

    # The handshake queued behind the flood for longer than the 5 s default;
    # the attempt's deadline carried it through and the work still ran.
    assert {:ok, :work_completed} = result
    assert Process.alive?(owner)
  end

  test "without a budget the subscribe registration still expires at the 5 s default",
       context do
    owner = start_server(context, __MODULE__.Agent)
    start_running_slice(owner, @request_id)
    flood_agent(owner)

    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        Aikido.AgentServer.subscribe(owner, "ai.react.**", fn _runtime -> {:ok, :never} end,
          once: true
        )

        :no_exit
      catch
        :exit, reason -> {:exit, reason}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    assert {:exit, {:timeout, {GenServer, :call, [^owner, {:subscribe, _, _, _, _, _}, 5_000]}}} =
             outcome

    assert elapsed in 4_000..9_000
  end

  test "an explicit :timeout option bounds the subscribe registration",
       context do
    owner = start_server(context, __MODULE__.Agent)
    start_running_slice(owner, @request_id)
    flood_agent(owner)

    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        Aikido.AgentServer.subscribe(owner, "ai.react.**", fn _runtime -> {:ok, :never} end,
          once: true,
          timeout: 200
        )

        :no_exit
      catch
        :exit, reason -> {:exit, reason}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    assert {:exit, {:timeout, {GenServer, :call, [^owner, {:subscribe, _, _, _, _, _}, 200]}}} =
             outcome

    assert elapsed < 3_000
  end

  defp start_running_slice(owner, request_id) do
    start =
      Aikido.Signal.new!("test.subscribe_budget.start", %{request_id: request_id})

    assert {:ok, :running} =
             Aikido.AgentServer.call(owner, start, fn runtime ->
               {:ok, runtime.agent.state.ai.status}
             end)
  end

  # The live busy-owner ingredient: the cast-per-chunk signal delivery the
  # real streaming provider path produces (`LLMCall.dispatch_stream_delta`).
  # Each cast runs the full server pipeline, so the flood drains slower than
  # the default call budget.
  defp flood_agent(agent_pid) do
    flood = Aikido.Signal.new!("test.subscribe_budget.flood", %{n: 1})

    tasks =
      for _ <- 1..4 do
        Task.async(fn -> cast_flood_signals(agent_pid, flood, div(@flood_signals, 4)) end)
      end

    Task.await_many(tasks, 120_000)
  end

  defp cast_flood_signals(agent_pid, flood, count) do
    for _ <- 1..count, do: Aikido.AgentServer.cast(agent_pid, flood)

    :ok
  end
end
