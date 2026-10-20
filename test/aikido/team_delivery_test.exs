defmodule Aikido.TeamDeliveryTest.Client do
  def generate_text(_, messages, opts) do
    if observer = opts[:observer] do
      send(observer, {:team_model, self(), messages})

      receive do
        {:answer, turn} -> {:ok, turn}
      end
    else
      answer(messages)
    end
  end

  defp answer(messages) do
    text = messages |> List.last() |> Map.fetch!(:content) |> Enum.map_join(& &1.text)

    {:ok,
     struct!(ReqLLM.Response,
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant(text, tool_calls: []),
       finish_reason: :stop
     )}
  end
end

defmodule Aikido.TeamDeliveryTest.Worker do
  use Ash.Resource,
    domain: Aikido.TeamDeliveryTest.Domain,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

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
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team, Aikido.Ash.AI]

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
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Ash.Domain]

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
    assert_receive {:aikido_subscription, ^replaced, %{result: {:ok, second}}}, 5_000
    refute first == second
    AikidoTest.LifecycleWait.await_down(model)
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
      struct!(ReqLLM.Response,
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message:
          ReqLLM.Context.assistant("",
            tool_calls: [%{id: "identity", name: "test_identity", arguments: %{}}]
          ),
        finish_reason: :tool_calls
      )

    final =
      struct!(ReqLLM.Response,
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message: ReqLLM.Context.assistant("done", tool_calls: []),
        finish_reason: :stop
      )

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

  test "task timeout cancels active work and releases the next queued job" do
    team = Domain.delivery_start!(%{})
    Domain.delivery_ensure_member!(team, %{member: :worker})
    payload = %{text: "wait", llm_opts: [observer: self()]}

    Domain.delivery_assign_task!(team, %{
      member: :worker,
      task_id: "slow",
      payload: payload,
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

    send(
      next,
      {:answer,
       struct!(ReqLLM.Response,
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("done", tool_calls: []),
         finish_reason: :stop
       )}
    )
  end

  test "worker cancellation releases queued work with external default dispatch", ctx do
    worker =
      start_server(ctx, Aikido.TeamDeliveryTest.Worker, default_dispatch: {:pid, target: self()})

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
       struct!(ReqLLM.Response,
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("done", tool_calls: []),
         finish_reason: :stop
       )}
    )

    assert_receive {:aikido_subscription, ^completed, %{result: {:ok, "done"}}}, 2_000
    refute_received {:signal, %{type: "ai.react.cancel"}}
  end

  test "restoration marks interrupted tasks explicitly instead of replaying effects" do
    state = %Aikido.Ash.Team.State{
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
    }

    restored = Aikido.Ash.Team.State.reinstate(state)
    assert restored.tasks["job"].status == :failed
    assert restored.tasks["job"].result == :interrupted
    assert restored.recovered_tasks == ["job"]
  end
end
