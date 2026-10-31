defmodule Aikido.ParentFailureTextContractTest.Client do
  @moduledoc false

  def generate_text(_model, messages, options) do
    observer = Keyword.fetch!(options, :observer)
    monitor = Process.monitor(observer)
    send(observer, {:parent_failure_model, self(), messages})

    try do
      receive do
        {:answer, response} -> {:ok, response}
        {:fail, reason} -> {:error, reason}
        {:DOWN, ^monitor, :process, ^observer, _} -> {:error, :synthetic_test_owner_stopped}
      after
        10_000 -> {:error, :synthetic_test_gate_timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end
end

defmodule Aikido.ParentFailureTextContractTest.Fixture.Worker do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.ParentFailureTextContractTest.Fixture.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "parent_failure_worker"
    instance Aikido.ParentFailureTextContractTest.Fixture.Instance
  end

  ai do
    model "offline"
    client Aikido.ParentFailureTextContractTest.Client
    options %{model_max_retries: 0}
  end
end

defmodule Aikido.ParentFailureTextContractTest.Fixture.Team do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.ParentFailureTextContractTest.Fixture.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension, Aikido.AI.Extension]

  agent do
    name "parent_failure_team"
    instance Aikido.ParentFailureTextContractTest.Fixture.Instance
  end

  ai do
    model "offline"
    client Aikido.ParentFailureTextContractTest.Client
    options %{model_max_retries: 0}
  end

  team do
    member :worker, Aikido.ParentFailureTextContractTest.Fixture.Worker, activation: :lazy
  end
end

defmodule Aikido.ParentFailureTextContractTest.Fixture.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :parent, Aikido.ParentFailureTextContractTest.Fixture.Team
    agent :worker, Aikido.ParentFailureTextContractTest.Fixture.Worker
  end
end

defmodule Aikido.ParentFailureTextContractTest do
  use ExUnit.Case, async: true
  import AikidoTest.Case, only: [unique_id: 1]

  setup context do
    case context[:fixture] do
      nil ->
        :ok

      {instance, domain} ->
        runtime =
          start_supervised!({Aikido, name: instance, durable: AikidoTest.Case.durable_options()})

        register_join(runtime)
        attempts = Process.whereis(Aikido.task_supervisor_name(instance))
        assert is_pid(attempts)
        register_join(attempts)
        %{instance: instance, domain: domain, runtime: runtime, attempts: attempts}
    end
  end

  @tag :r1_parent_text
  @tag fixture:
         {Aikido.ParentFailureTextContractTest.Fixture.Instance,
          Aikido.ParentFailureTextContractTest.Fixture.Domain}
  test "unknown tuple worker failures omit raw details from the actual parent request", ctx do
    assert_runtime_retires(ctx, fn ->
      sentinel = "SYNTHETIC-R1-ONLY"
      reason = {:synthetic_failure, %{credential: sentinel}}
      {state, text} = deliver_worker_failure(ctx, reason)
      assert state.team.tasks["failed-job"].result == reason
      assert state.ai.run_metadata.task.result == reason
      refute text =~ sentinel
      assert text =~ "failed without a public error description"
    end)
  end

  @tag :r1_parent_text
  @tag fixture:
         {Aikido.ParentFailureTextContractTest.Fixture.Instance,
          Aikido.ParentFailureTextContractTest.Fixture.Domain}
  test "unknown map worker failures omit raw details from the actual parent request", ctx do
    assert_runtime_retires(ctx, fn ->
      sentinel = "SYNTHETIC-R1-ONLY"
      reason = %{credential: sentinel, nested: %{body: sentinel}}
      {state, text} = deliver_worker_failure(ctx, reason)
      assert state.team.tasks["failed-job"].result == reason
      assert state.ai.run_metadata.task.result == reason
      refute text =~ sentinel
      assert text =~ "failed without a public error description"
    end)
  end

  @tag :r1_parent_text
  @tag fixture:
         {Aikido.ParentFailureTextContractTest.Fixture.Instance,
          Aikido.ParentFailureTextContractTest.Fixture.Domain}
  test "unknown binary worker failures omit raw details from the actual parent request", ctx do
    assert_runtime_retires(ctx, fn ->
      sentinel = "SYNTHETIC-R1-ONLY"
      reason = sentinel
      {state, text} = deliver_worker_failure(ctx, reason)
      assert state.team.tasks["failed-job"].result == reason
      assert state.ai.run_metadata.task.result == reason
      refute text =~ sentinel
      assert text =~ "failed without a public error description"
    end)
  end

  @tag :r1_parent_text
  @tag fixture:
         {Aikido.ParentFailureTextContractTest.Fixture.Instance,
          Aikido.ParentFailureTextContractTest.Fixture.Domain}
  test "authored worker failures retain useful guidance in the actual parent request", ctx do
    assert_runtime_retires(ctx, fn ->
      reason =
        Aikido.AiReact.Errors.ProviderRequestFailed.exception(
          cause_type: ReqLLM.Error.API.Request,
          status: 429
        )

      {state, text} = deliver_worker_failure(ctx, reason)
      assert state.team.tasks["failed-job"].result == reason
      assert text =~ "HTTP 429"
      assert text =~ "backoff"
    end)
  end

  test "native missing-model results retain configuration guidance and raw metadata" do
    signal =
      Aikido.Team.TaskDelivery.conversation_message_for_task_result(%{
        id: "no-model-job",
        member: :worker,
        status: :failed,
        result: :no_model
      })

    assert signal.data.text =~ "no model configured"
    assert signal.data.text =~ "before assigning new work"
    assert signal.data.metadata.task.result == :no_model
  end

  defp deliver_worker_failure(ctx, reason) do
    team =
      ctx.domain.parent_start!(%{id: unique_id("failed-delivery"), llm_opts: [observer: self()]})

    parent_down = register_join(team.pid)

    {:ok, failed} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "aikido.ash.team.task.failed",
        fn runtime ->
          case runtime.agent.state.team.tasks["failed-job"] do
            %{status: :failed} = task -> {:ok, task}
            _ -> :skip
          end
        end,
        once: true
      )

    {:ok, completed} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "**",
        fn runtime ->
          ai = runtime.agent.state.ai

          if ai.status == :completed && ai.request_id == "task-result/failed-job",
            do: {:ok, runtime.agent.state},
            else: :skip
        end,
        once: true
      )

    ctx.domain.parent_assign_task!(
      team,
      %{
        member: :worker,
        task_id: "failed-job",
        mode: :background,
        notify: :self,
        metadata: %{workflow_step_id: "synthetic-step"},
        payload: %{text: "synthetic failure scenario", llm_opts: [observer: self()]}
      }
    )

    assert_receive {:parent_failure_model, worker_attempt, _worker_messages}, 5_000
    worker_down = register_join(worker_attempt)
    snapshot = ctx.domain.parent_inspect!(team)
    child = snapshot.team.members.worker
    child_down = register_join(child)
    send(worker_attempt, {:fail, reason})
    assert_receive {:aikido_subscription, ^failed, %{result: {:ok, task}}}, 5_000
    assert task.result == reason
    assert is_binary(task.attempt)
    assert task.member == :worker
    assert_receive {:DOWN, ^worker_down, :process, ^worker_attempt, _}, 5_000

    assert_receive {:parent_failure_model, parent_attempt, messages}, 5_000
    attempt_down = register_join(parent_attempt)
    text = messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", &(&1.text || ""))

    send(
      parent_attempt,
      {:answer,
       %ReqLLM.Response{
         id: "synthetic-parent",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant(text, tool_calls: []),
         finish_reason: :stop
       }}
    )

    assert_receive {:aikido_subscription, ^completed, %{result: {:ok, state}}}, 5_000
    assert_receive {:DOWN, ^attempt_down, :process, ^parent_attempt, _}, 5_000
    assert state.ai.run_metadata.task.id == "failed-job"
    assert state.ai.run_metadata.task.metadata == %{workflow_step_id: "synthetic-step"}
    assert {:ok, _receipt} = ctx.domain.parent_stop(team)
    assert_receive {:DOWN, ^parent_down, :process, _, _}, 5_000
    assert_receive {:DOWN, ^child_down, :process, ^child, _}, 5_000
    assert text =~ "Task failed-job from worker failed"
    {state, text}
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

  defp register_join(pid) do
    on_exit(fn -> assert :ok = AikidoTest.LifecycleWait.await_down(pid, 10_000) end)
    Process.monitor(pid)
  end
end
