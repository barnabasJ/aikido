defmodule Aikido.WorkerLaunchTest.Client do
  def generate_text(model, _messages, opts) do
    if observer = opts[:observer], do: send(observer, {:worker_model, model})

    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant("done", tool_calls: []),
       finish_reason: :stop
     }}
  end
end

defmodule Aikido.WorkerLaunchTest.Worker do
  use Ash.Resource,
    domain: Aikido.WorkerLaunchTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "worker_launch"
  end

  ai do
    client Aikido.WorkerLaunchTest.Client
  end
end

defmodule Aikido.WorkerLaunchTest.Team do
  use Ash.Resource,
    domain: Aikido.WorkerLaunchTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "worker_launch_team"
  end

  team do
    member :worker, Aikido.WorkerLaunchTest.Worker, activation: :lazy
  end
end

defmodule Aikido.WorkerLaunchTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :launch, Aikido.WorkerLaunchTest.Team
    agent :worker, Aikido.WorkerLaunchTest.Worker
  end
end

defmodule Aikido.WorkerLaunchTest do
  use AikidoTest.Case, async: false

  alias Aikido.WorkerLaunchTest.Domain

  test "typed todo changes defer settlement through the worker's schema-backed observer" do
    signal = Aikido.Todo.Signals.TodoChanged.new!(%{})
    state = Ash.create!(Aikido.AiWorker.Slice, %{pending: %{task_id: "waiting"}})

    route =
      Aikido.AiWorker.Slice
      |> Spark.Dsl.Extension.get_entities([:slice])
      |> Enum.find(&(&1.type == signal.type))

    assert route.signal_module == Aikido.Todo.Signals.TodoChanged
    assert {Aikido.AiWorker.Slice, action} = route.action

    assert {:ok, result} =
             Aikido.AiWorker.Slice
             |> Ash.ActionInput.for_action(action, %{state: state},
               context: %{aikido: %{signal: signal, agent_pid: self()}}
             )
             |> Ash.run_action()

    assert result.changes == %{}

    assert [directive] = result.directives
    assert directive.target == self()
    assert directive.signal.type == "harness.ai.observe"
    assert directive.signal.data.task_id == "waiting"
  end

  test "a missing model fails the team's task before its deadline and permits the next task" do
    start_supervised!({Aikido, name: Aikido.Default, durable: AikidoTest.Case.durable_options()})
    team = Domain.launch_start!(%{})

    {:ok, failed} = task_subscription(team.pid, "missing", :failed)

    Domain.launch_assign_task!(team, %{
      member: :worker,
      task_id: "missing",
      payload: %{text: "work"},
      timeout_ms: 60_000
    })

    assert_receive {:aikido_subscription, ^failed, %{result: {:ok, task}}}, 2_000
    assert task.result == :no_model
    assert task.member == :worker
    assert is_binary(task.attempt)

    worker = Domain.launch_inspect!(team).team.members.worker

    assert {:ok, %{pending: nil, completed: 1}} =
             Aikido.AgentServer.state(worker, &{:ok, &1.agent.state.work})

    {:ok, completed} = task_subscription(team.pid, "valid", :completed)

    Domain.launch_assign_task!(team, %{
      member: :worker,
      task_id: "valid",
      payload: %{text: "work", model: "offline", llm_opts: [observer: self()]},
      timeout_ms: 60_000
    })

    assert_receive {:worker_model, "offline"}, 2_000
    assert_receive {:aikido_subscription, ^completed, %{result: {:ok, task}}}, 2_000
    assert task.result == "done"

    assert {:ok, %{pending: nil, completed: 2}} =
             Aikido.AgentServer.state(worker, &{:ok, &1.agent.state.work})
  end

  test "queued missing models retain every correlated failure and caller scope before valid work" do
    missing_one = task("missing-one", nil, %{actor: :alice, tenant: "one"})
    missing_two = task("missing-two", nil, %{actor: :bob, tenant: "two"})
    valid = task("valid", "offline", %{actor: :carol, tenant: "three"})
    state = Ash.create!(Aikido.AiWorker.Slice, %{queue: [missing_one, missing_two, valid]})

    assert {:ok, result} = run_action(:settle, %{state: state}, nil)
    assert result.changes.queue == []
    assert result.changes.pending.task_id == "valid"
    assert result.changes.completed == 2

    assert [first, second, ask] = result.directives

    for {directive, task} <- [{first, missing_one}, {second, missing_two}] do
      assert directive.target == self()
      assert directive.signal.type == "aikido.ash.team.task.failed"

      assert directive.signal.data == %{
               task_id: task.task_id,
               member: :worker,
               attempt: task.attempt,
               result: :no_model
             }

      assert directive.signal.scope == task.signal_context
    end

    assert ask.signal.type == "ai.react.ask"
    assert ask.signal.data.request_id == "valid"
    assert ask.signal.data.model == "offline"
    assert ask.signal.scope == valid.signal_context
  end

  test "configured models and per-task overrides launch while duplicate admission is unchanged" do
    for {task_model, configured_model, expected} <- [
          {nil, "configured", nil},
          {"override", "configured", "override"}
        ] do
      params = task("valid", task_model, %{}) |> Map.delete(:signal_context)

      assert {:ok, result} =
               run_action(
                 :accept,
                 Map.put(params, :state, Ash.create!(Aikido.AiWorker.Slice, %{})),
                 configured_model
               )

      assert result.changes.pending.task_id == "valid"
      assert result.changes.completed == 0
      assert [ask] = result.directives
      assert ask.signal.type == "ai.react.ask"
      assert ask.signal.data.model == expected
    end

    params = task("duplicate", nil, %{}) |> Map.delete(:signal_context)

    for state <- [
          Ash.create!(Aikido.AiWorker.Slice, %{
            pending: Map.take(params, [:task_id, :member, :attempt, :reply_to])
          }),
          Ash.create!(Aikido.AiWorker.Slice, %{queue: [params]})
        ] do
      assert {:ok, result} = run_action(:accept, Map.put(params, :state, state), nil)

      assert result.changes == %{}

      assert result.directives == []
    end
  end

  defp task(id, model, scope) do
    %{
      task_id: id,
      member: :worker,
      attempt: "attempt-#{id}",
      reply_to: self(),
      text: "work",
      model: model,
      signal_context: scope
    }
  end

  defp run_action(action, params, model) do
    signal = Aikido.Signal.new!("harness.test", %{task_id: "observation"})

    Aikido.AiWorker.Slice
    |> Ash.ActionInput.for_action(action, params,
      context: %{
        aikido: %{
          signal: signal,
          agent_pid: self(),
          agent: %{state: %{ai: %{model: model, status: :idle}}}
        }
      }
    )
    |> Ash.run_action()
  end

  defp task_subscription(pid, id, status) do
    Aikido.AgentServer.subscribe(
      pid,
      "**",
      fn runtime ->
        case runtime.agent.state.team.tasks[id] do
          %{status: ^status} = task -> {:ok, task}
          _ -> :skip
        end
      end,
      once: true
    )
  end
end
