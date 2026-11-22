defmodule Aikido.TeamDeliveryTest.Client do
  def generate_text(_, messages, opts) do
    if observer = opts[:observer] do
      send(observer, {:team_model, self(), messages})

      receive do
        {:answer, turn} -> {:ok, turn}
        {:failure, reason} -> {:error, reason}
      end
    else
      answer(messages)
    end
  end

  defp answer(messages) do
    text = messages |> List.last() |> Map.fetch!(:content) |> Enum.map_join(& &1.text)

    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant(text, tool_calls: []),
       finish_reason: :stop
     }}
  end
end

defmodule Aikido.TeamDeliveryTest.Worker do
  use Ash.Resource,
    domain: Aikido.TeamDeliveryTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "delivery_worker"
  end

  ai do
    model "offline"
    client Aikido.TeamDeliveryTest.Client
  end
end

defmodule Aikido.TeamDeliveryTest.Team do
  use Ash.Resource,
    domain: Aikido.TeamDeliveryTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension, Aikido.AI.Extension]

  agent do
    name "delivery_team"
  end

  ai do
    model "offline"
    client Aikido.TeamDeliveryTest.Client
  end

  team do
    member :worker, Aikido.TeamDeliveryTest.Worker, activation: :lazy
  end
end

defmodule Aikido.TeamDeliveryTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :delivery, Aikido.TeamDeliveryTest.Team
    agent :worker, Aikido.TeamDeliveryTest.Worker
  end
end

defmodule Aikido.TeamDeliveryTest do
  use AikidoTest.Case, async: false
  alias Aikido.TeamDeliveryTest.Domain

  setup do
    start_supervised!({Aikido, name: Aikido.Default, durable: AikidoTest.Case.durable_options()})
    :ok
  end

  test "background failures without a public error protocol omit private exception contents" do
    signal =
      Aikido.Team.TaskDelivery.conversation_message_for_task_result(%{
        id: "failed-task",
        member: :worker,
        status: :failed,
        result: RuntimeError.exception("private-provider-key")
      })

    assert signal.data.text =~ "RuntimeError"
    assert signal.data.text =~ "Inspect the worker's state"
    refute signal.data.text =~ "private-provider-key"
  end

  test "bare timeout narration is non-prescriptive and typed causes keep their own details" do
    task = %{id: "timed-task", member: :worker, status: :failed, result: :timeout}
    text = Aikido.Team.TaskDelivery.conversation_message_for_task_result(task).data.text
    assert text =~ "does not specify which timer fired"
    refute text =~ "expired"
    refute text =~ "retry"
    refute text =~ "larger budget"

    error =
      Aikido.AiReact.Errors.ProviderRequestFailed.exception(
        timeout_phase: :receive,
        timeout_ms: 20_000
      )

    typed = Aikido.Team.TaskDelivery.conversation_message_for_task_result(%{task | result: error})
    assert typed.data.text =~ AshAi.ToToolError.to_tool_error(error)
    refute typed.data.text =~ "does not specify which timer fired"
  end

  test "delegation activates a lazy worker and its result wakes the team through its AI interface" do
    team = Domain.delivery_start!(%{})

    {:ok, done} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "**",
        fn runtime ->
          if runtime.agent.state.ai.status == :completed,
            do: {:ok, runtime.agent.state},
            else: :skip
        end,
        once: true
      )

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "job",
      payload: %{text: "work"},
      notify: :self,
      metadata: %{workflow_step_id: "application-owned"}
    })

    assert_receive {:aikido_subscription, ^done, %{result: {:ok, state}}}, 5_000
    assert state.team.tasks["job"].status == :completed
    assert state.ai.result =~ "Task job from worker completed"
    assert state.ai.run_metadata.task.metadata == %{workflow_step_id: "application-owned"}
    assert state.team.pending_tasks == %{}
  end

  test "a lost worker fails its task and is replaced in the team roster" do
    team = Domain.delivery_start!(%{})
    Domain.delivery_ensure_member!(team, %{member: :worker})
    snapshot = Domain.delivery_inspect!(team)
    first = snapshot.team.members.worker

    {:ok, replaced} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "**",
        fn runtime ->
          case runtime.agent.state.team.members[:worker] do
            pid when is_pid(pid) and pid != first -> {:ok, pid}
            _ -> :skip
          end
        end,
        once: true
      )

    {:ok, failed} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "**",
        fn runtime ->
          case runtime.agent.state.team.tasks["lost"] do
            %{status: :failed} = task -> {:ok, task}
            _ -> :skip
          end
        end,
        once: true
      )

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "lost",
      payload: %{text: "wait", llm_opts: [observer: self()]}
    })

    assert_receive {:team_model, model, _}, 5_000
    Process.exit(first, :kill)
    assert_receive {:aikido_subscription, ^failed, %{result: {:ok, task}}}, 5_000
    assert task.result == :member_exited
    assert task.member == :worker
    failure = Aikido.Team.TaskDelivery.conversation_message_for_task_result(task)
    assert failure.data.text =~ "worker process exited"
    assert failure.data.text =~ "ensure a replacement is ready"
    assert_receive {:aikido_subscription, ^replaced, %{result: {:ok, second}}}, 5_000
    refute first == second
    AikidoTest.LifecycleWait.await_down(model)
  end

  test "a truncated worker response delivers recovery guidance to a background requester" do
    team = Domain.delivery_start!(%{})

    {:ok, done} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "**",
        fn runtime ->
          if runtime.agent.state.ai.status == :completed,
            do: {:ok, runtime.agent.state},
            else: :skip
        end,
        once: true
      )

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "limited-job",
      payload: %{text: "wait", llm_opts: [observer: self(), max_tokens: 32]},
      mode: :background,
      notify: :self
    })

    assert_receive {:team_model, model, _}, 5_000

    send(
      model,
      {:answer,
       %ReqLLM.Response{
         id: "limited-report",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("unfinished report"),
         finish_reason: :length
       }}
    )

    assert_receive {:aikido_subscription, ^done, %{result: {:ok, state}}}, 5_000
    assert state.team.tasks["limited-job"].status == :failed

    assert %Aikido.AiReact.Errors.OutputTruncated{max_tokens: 32} =
             state.team.tasks["limited-job"].result

    assert state.ai.result =~ "Increase max_tokens"
    assert state.ai.result =~ "reasoning may share this budget"
    refute state.ai.result =~ "unfinished report"
  end

  test "queued worker jobs preserve each caller scope", _ctx do
    team = Domain.delivery_start!(%{})
    Domain.delivery_ensure_member!(team, %{member: :worker})

    payload = %{
      text: "identify",
      tools: [:test_identity],
      tool_options: [otp_app: :aikido],
      tool_context: %{context: %{observer: self()}},
      llm_opts: [observer: self()]
    }

    Domain.delivery_assign_task!(team, %{member: :worker, task_id: "alice", payload: payload},
      actor: %{id: "alice"},
      tenant: "a"
    )

    assert_receive {:team_model, first, _}, 2_000

    Domain.delivery_assign_task!(team, %{member: :worker, task_id: "bob", payload: payload},
      actor: %{id: "bob"},
      tenant: "b"
    )

    tool_turn =
      %ReqLLM.Response{
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message:
          ReqLLM.Context.assistant("",
            tool_calls: [%{id: "identity", name: "test_identity", arguments: %{}}]
          ),
        finish_reason: :tool_calls
      }

    final =
      %ReqLLM.Response{
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message: ReqLLM.Context.assistant("done", tool_calls: []),
        finish_reason: :stop
      }

    send(first, {:answer, tool_turn})
    assert_receive {:tool_scope, "alice", "a"}, 2_000
    assert_receive {:team_model, finish_first, _}, 2_000
    send(finish_first, {:answer, final})
    assert_receive {:team_model, second, _}, 2_000
    send(second, {:answer, tool_turn})
    assert_receive {:team_model, finish_second, messages}, 2_000

    assert_receive {:tool_scope, "bob", "b"},
                   2_000,
                   inspect(Enum.flat_map(messages, & &1.content) |> Enum.map(& &1.text))

    send(finish_second, {:answer, final})
  end

  test "a worker-reported timeout does not claim that the assignment budget expired" do
    team = Domain.delivery_start!(%{})

    {:ok, failed_ref} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "aikido.ash.team.task.failed",
        fn runtime -> {:ok, runtime.agent.state.team.tasks["worker-timeout"]} end,
        once: true
      )

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "worker-timeout",
      payload: %{text: "work", llm_opts: [observer: self()]},
      notify: :self,
      timeout_ms: 13_814_000
    })

    assert_receive {:team_model, model, _}, 5_000

    assert {:ok, worker} =
             Aikido.AgentServer.state(team.pid, &{:ok, &1.agent.state.team.members.worker})

    {:ok, cancelled_ref} =
      Aikido.AgentServer.subscribe(worker, "harness.cancel_task", fn _ -> {:ok, :cancelled} end,
        once: true
      )

    send(model, {:failure, :timeout})

    assert_receive {:aikido_subscription, ^failed_ref,
                    %{result: {:ok, %{status: :failed, result: :timeout}}}},
                   5_000

    state =
      AikidoTest.AgentWait.await_state_value(team.pid, fn runtime ->
        if runtime.agent.state.ai.status == :completed, do: runtime.agent.state
      end)

    assert state.ai.result =~ "reported a timeout"
    refute state.ai.result =~ "deadline expired"
    refute state.ai.result =~ "cancellation was requested"
    refute_received {:aikido_subscription, ^cancelled_ref, _}
  end

  test "task timeout cancels active work and releases the next queued job" do
    team = Domain.delivery_start!(%{})
    Domain.delivery_ensure_member!(team, %{member: :worker})
    payload = %{text: "wait", llm_opts: [observer: self()]}

    {:ok, delivered} =
      Aikido.AgentServer.subscribe(
        team.pid,
        "ai.react.deliver",
        fn _runtime, event ->
          {:ok, event.signal.data.text}
        end,
        once: true
      )

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "slow",
      payload: payload,
      notify: :self,
      timeout_ms: 250
    })

    assert_receive {:team_model, slow, _}, 2_000
    monitor = Process.monitor(slow)

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "next",
      payload: payload,
      timeout_ms: 5_000
    })

    assert_receive {:DOWN, ^monitor, :process, ^slow, _}, 2_000
    assert_receive {:team_model, next, _}, 2_000
    assert_receive {:aikido_subscription, ^delivered, %{result: {:ok, message}}}, 2_000
    assert message =~ "stage assigned_task"
    assert message =~ "after 250ms"
    assert message =~ ~s(task_id="slow")

    send(
      next,
      {:answer,
       %ReqLLM.Response{
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("done", tool_calls: []),
         finish_reason: :stop
       }}
    )
  end

  test "worker cancellation releases queued work with direct internal delivery", ctx do
    worker =
      start_server(ctx, Aikido.TeamDeliveryTest.Worker)

    task_data = %{
      member: :worker,
      attempt: "incarnation",
      reply_to: self(),
      text: "wait",
      model: "offline",
      client: Aikido.TeamDeliveryTest.Client,
      llm_opts: [observer: self()]
    }

    assert {:ok, _} =
             Aikido.AgentServer.call(
               worker,
               signal("harness.task", Map.put(task_data, :task_id, "slow")),
               &{:ok, &1.agent.state.work}
             )

    assert_receive {:team_model, slow, _}, 2_000

    assert {:ok, %{queue: [%{task_id: "next"}]}} =
             Aikido.AgentServer.call(
               worker,
               signal("harness.task", Map.put(task_data, :task_id, "next")),
               &{:ok, &1.agent.state.work}
             )

    monitor = Process.monitor(slow)

    {:ok, completed} =
      Aikido.AgentServer.subscribe(
        worker,
        "**",
        fn runtime ->
          if runtime.agent.state.work.completed == 1,
            do: {:ok, runtime.agent.state.ai.result},
            else: :skip
        end,
        once: true
      )

    assert :ok =
             Aikido.AgentServer.cast(worker, signal("harness.cancel_task", %{task_id: "slow"}))

    assert_receive {:DOWN, ^monitor, :process, ^slow, _}, 2_000
    assert_receive {:team_model, next, _}, 2_000

    send(
      next,
      {:answer,
       %ReqLLM.Response{
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("done", tool_calls: []),
         finish_reason: :stop
       }}
    )

    assert_receive {:aikido_subscription, ^completed, %{result: {:ok, "done"}}}, 2_000
    refute_received {:signal, %{type: "ai.react.cancel"}}
  end

  test "restoration marks interrupted tasks explicitly instead of replaying effects" do
    state =
      Ash.create!(Aikido.Team.Slice, %{
        tasks: %{
          "job" => %{
            id: "job",
            member: :worker,
            status: :dispatched,
            result: nil,
            attempt: "old",
            notify: :self,
            metadata: %{}
          }
        }
      })

    restored = Aikido.Team.Slice.reinstate(state)
    assert restored.tasks["job"].status == :failed
    assert restored.tasks["job"].result == :interrupted
    assert restored.recovered_tasks == ["job"]
  end
end
