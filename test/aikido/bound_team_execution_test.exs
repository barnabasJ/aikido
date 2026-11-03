defmodule Aikido.BoundTeamExecutionTest.Authority do
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    actor_id = get_in(attributes, [:state, :actor_id])

    options =
      if actor_id,
        do: Keyword.put(options, :actor, %{id: actor_id, allowed: true}),
        else: options

    AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.BoundTeamExecutionTest.Prepare do
  use Ash.Resource, domain: Aikido.BoundTeamExecutionTest.Domain

  actions do
    action :prepare, :term do
      argument :options, :term
      argument :metadata, :map

      run fn input, context ->
        observer = get_in(context.source_context, [:shared, :observer])

        send(
          observer,
          {:preparing, context.actor.id, context.tenant, self(),
           context.source_context[:aikido_sender]}
        )

        if input.arguments.metadata[:hold] do
          receive do
            :release -> :ok
          end
        end

        {:ok, input.arguments.options}
      end
    end
  end
end

defmodule Aikido.BoundTeamExecutionTest.Client do
  def generate_text(_model, _messages, _options) do
    {:ok,
     %ReqLLM.Response{
       id: "bound-result",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant("done"),
       finish_reason: :stop
     }}
  end
end

defmodule Aikido.BoundTeamExecutionTest.OwnActor do
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "the authenticated actor owns the current agent"

  @impl true
  def match?(%{id: id}, %{subject: %Ash.Changeset{data: %{actor_id: id}}}, _options),
    do: true

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.BoundTeamExecutionTest.Worker do
  use Ash.Resource,
    domain: Aikido.BoundTeamExecutionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "bound_worker"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Execution identity authenticated by the test authority."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline"
    client Aikido.BoundTeamExecutionTest.Client
    options %{tool_preparation: {Aikido.BoundTeamExecutionTest.Prepare, :prepare}}
  end

  policies do
    policy action_type(:update) do
      authorize_if Aikido.BoundTeamExecutionTest.OwnActor
    end

    policy action_type([:create, :action]) do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.BoundTeamExecutionTest.Team do
  use Ash.Resource,
    domain: Aikido.BoundTeamExecutionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension, Aikido.AI.Extension]

  agent do
    name "bound_team"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Coordinator identity authenticated at activation."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline"
    client Aikido.BoundTeamExecutionTest.Client

    options %{
      completion: :tasks,
      tool_preparation: {Aikido.BoundTeamExecutionTest.Prepare, :prepare}
    }
  end

  team do
    member :worker, Aikido.BoundTeamExecutionTest.Worker, initial_state: %{actor_id: "worker-B"}
  end

  policies do
    policy action_type(:update) do
      authorize_if Aikido.BoundTeamExecutionTest.OwnActor
    end

    policy action_type([:create, :action]) do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.BoundTeamExecutionTest.Unbound do
  use Ash.Resource,
    domain: Aikido.BoundTeamExecutionTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "unbound"
  end
end

defmodule Aikido.BoundTeamExecutionTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.BoundTeamExecutionTest.Prepare
  end

  agents do
    agent :bound_team, Aikido.BoundTeamExecutionTest.Team
    agent :bound_worker, Aikido.BoundTeamExecutionTest.Worker
    agent :unbound, Aikido.BoundTeamExecutionTest.Unbound
  end
end

defmodule Aikido.BoundTeamExecutionTest do
  use AikidoTest.Case, async: false
  alias Aikido.BoundTeamExecutionTest.{Domain, Team, Worker}

  setup do
    options =
      Keyword.put(durable_options(), :scope_adapter, Aikido.BoundTeamExecutionTest.Authority)

    start_supervised!({Aikido, name: Aikido.Default, durable: options})
    actor = %{id: "coordinator-A", allowed: true}

    scope = %{
      actor: actor,
      tenant: "bound-tenant",
      context: %{
        shared: %{observer: self()},
        aikido_runtime_options: [partition: "private-partition"]
      }
    }

    team = Domain.bound_team_start!(%{actor_id: actor.id}, scope: scope, context: scope.context)
    assert_receive {:durable_authentication, %{agent_module: Team}}, 5_000
    assert_receive {:durable_authentication, %{agent_module: Worker}}, 5_000
    {:ok, team: team, scope: scope}
  end

  test "caller A assigns, worker B executes, and the correlated result resumes A", %{
    team: team,
    scope: scope
  } do
    Domain.bound_team_ask!(
      team,
      %{
        query: "coordinate",
        request_id: "parent-run",
        metadata: %{hold: true}
      },
      scope: scope
    )

    assert_receive {:preparing, "coordinator-A", "bound-tenant", parent_work, _}, 5_000

    Domain.bound_team_assign_task!(
      team,
      %{
        member: :worker,
        task_id: "child-task",
        mode: :background,
        notify: :self,
        metadata: %{hold: true},
        payload: %{text: "research"}
      },
      scope: scope
    )

    assert_receive {:preparing, "worker-B", "bound-tenant", child_work, sender}, 5_000
    assert sender.id == team.id
    send(parent_work, :release)

    await_state_value(
      team.pid,
      fn runtime -> if runtime.agent.state.ai.status == :waiting, do: true end,
      timeout: 5_000
    )

    send(child_work, :release)

    state =
      await_state_value(
        team.pid,
        fn runtime -> if runtime.agent.state.ai.status == :completed, do: runtime.agent.state end,
        timeout: 5_000
      )

    assert state.ai.request_id == "parent-run"
    assert state.ai.run_scope.actor.id == "coordinator-A"
    assert state.team.tasks["child-task"].status == :completed
    assert [%{request_id: "task-result/child-task"}] = state.ai.run_metadata.deliveries
    worker = state.team.members.worker

    assert {:ok, "worker-B"} =
             Aikido.AgentServer.state(worker, &{:ok, &1.agent.state.ai.run_scope.actor.id})

    refute_receive {:durable_authentication, _}

    saved =
      :sys.get_state(team.pid).user_state
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

    refute inspect(saved, limit: :infinity) =~ "bound_execution_scope"
    refute inspect(saved, limit: :infinity) =~ "allowed: true"
    refute Keyword.has_key?(saved.options, :initialization_options)
  end

  test "external callers are not rewritten to the activation actor", %{team: team, scope: scope} do
    foreign = %{scope | actor: %{id: "other-C", allowed: true}}
    assert {:error, reason} = Domain.bound_team_ask(team, %{query: "impersonate"}, scope: foreign)
    assert %Ash.Error.Forbidden{errors: errors} = reason
    assert Enum.any?(errors, &match?(%Aikido.Agent.Errors.ExecutionIdentityRequiresRestart{}, &1))
    assert Exception.message(reason) =~ "stop and restart"

    assert {:ok, "coordinator-A"} =
             Aikido.AgentServer.state(team.pid, &{:ok, &1.bound_execution_scope.actor.id})

    assert {:error, _} =
             Domain.bound_team_assign_task(team, %{member: :worker, payload: %{text: "denied"}},
               scope: %{scope | actor: %{id: "denied", allowed: false}}
             )
  end

  test "configured delivery types must match before recipient authority is applied", %{team: team} do
    assert {:ok, {sender, worker}} =
             Aikido.AgentServer.state(team.pid, fn runtime ->
               sender = %{
                 id: runtime.id,
                 pid: team.pid,
                 resource: runtime.agent_module,
                 aikido: runtime.aikido,
                 partition: runtime.partition
               }

               {:ok, {sender, runtime.agent.state.team.members.worker}}
             end)

    configured =
      Aikido.Signal.new!("application.custom_task", %{
        task_id: "configured-task",
        member: :worker,
        reply_to: team.pid,
        text: "custom work"
      })

    altered = %{configured | type: "ai.react.cancel"}

    assert {:ok, :checked} =
             Aikido.AgentServer.state(worker, fn runtime ->
               for kind <- [:task, :message] do
                 correlation = %{kind: kind, signal_type: configured.type}

                 assert {:ok, received} =
                          Aikido.Signal.Delivery.receive_signal(
                            runtime,
                            Aikido.Team.Delivery,
                            sender,
                            configured,
                            correlation
                          )

                 assert received.scope.actor.id == "worker-B"

                 assert :ignore =
                          Aikido.Signal.Delivery.receive_signal(
                            runtime,
                            Aikido.Team.Delivery,
                            sender,
                            altered,
                            correlation
                          )
               end

               {:ok, :checked}
             end)
  end

  test "execution identity query uses the immutable binding and native command authorization", %{
    team: team,
    scope: scope
  } do
    assert Domain.bound_team_execution_identity_matches!(team, scope: scope) === true

    assert Domain.bound_team_execution_identity_matches!(team,
             scope: %{scope | actor: %{id: "other-C", allowed: true}}
           ) === false

    assert Domain.bound_team_execution_identity_matches!(team,
             scope: %{scope | tenant: "other-tenant"}
           ) === false

    assert {:error, _} =
             Domain.bound_team_execution_identity_matches(team,
               scope: %{scope | actor: %{id: "denied", allowed: false}}
             )
  end

  test "an unbound activation cannot prove an execution identity" do
    unbound = Domain.unbound_start!(%{})
    assert Domain.unbound_execution_identity_matches!(unbound) === false

    assert Domain.unbound_execution_identity_matches!(unbound,
             scope: %{actor: %{id: "caller", allowed: true}}
           ) === false
  end

  test "accepted delivery IDs survive later runs and durable restoration", %{
    team: team,
    scope: scope
  } do
    delivery = %{text: "one result", request_id: "stable-delivery", metadata: %{hold: true}}
    Domain.bound_team_deliver!(team, delivery, scope: scope)
    assert_receive {:preparing, "coordinator-A", _, work, _}, 5_000
    send(work, :release)
    await_completed_request(team, "stable-delivery")

    Domain.bound_team_ask!(
      team,
      %{query: "later request", request_id: "later-run", metadata: %{hold: true}},
      scope: scope
    )

    assert_receive {:preparing, "coordinator-A", _, later_work, _}, 5_000
    send(later_work, :release)
    await_completed_request(team, "later-run")

    foreign = %{scope | actor: %{id: "other-C", allowed: true}}
    assert {:error, _} = Domain.bound_team_deliver(team, delivery, scope: foreign)
    Domain.bound_team_deliver!(team, delivery, scope: scope)

    assert {:ok, "later-run"} =
             Aikido.AgentServer.state(team.pid, &{:ok, &1.agent.state.ai.request_id})

    refute_received {:preparing, _, _, _, _}

    Domain.bound_team_stop!(team, scope: scope)
    context = Map.put(scope.context, :aikido_runtime_options, partition: "private-partition")

    restored =
      Domain.bound_team_start!(%{id: team.id, actor_id: scope.actor.id},
        scope: scope,
        context: context
      )

    Domain.bound_team_deliver!(restored, delivery, scope: scope)

    assert {:ok, {"later-run", ["stable-delivery"]}} =
             Aikido.AgentServer.state(restored.pid, fn runtime ->
               ai = runtime.agent.state.ai
               {:ok, {ai.request_id, ai.accepted_delivery_ids}}
             end)

    refute_received {:preparing, _, _, _, _}
  end

  defp await_completed_request(team, request_id) do
    await_state_value(
      team.pid,
      fn runtime ->
        ai = runtime.agent.state.ai
        if ai.status == :completed && ai.request_id == request_id, do: true
      end,
      timeout: 5_000
    )
  end

  test "a result arriving after its parent's cancellation cannot start another run", %{
    team: team,
    scope: scope
  } do
    Domain.bound_team_ask!(
      team,
      %{query: "coordinate", request_id: "cancelled-parent", metadata: %{hold: true}},
      scope: scope
    )

    assert_receive {:preparing, "coordinator-A", _, _parent_work, _}, 5_000

    Domain.bound_team_assign_task!(
      team,
      %{
        member: :worker,
        task_id: "late",
        notify: :self,
        metadata: %{hold: true},
        payload: %{text: "research"}
      },
      scope: scope
    )

    assert_receive {:preparing, "worker-B", _, child_work, _}, 5_000
    Domain.bound_team_cancel!(team, %{request_id: "cancelled-parent"}, scope: scope)
    send(child_work, :release)

    state =
      await_state_value(
        team.pid,
        fn runtime ->
          if runtime.agent.state.team.tasks["late"].status == :completed, do: runtime.agent.state
        end,
        timeout: 5_000
      )

    assert state.ai.status == :failed
    assert state.ai.request_id == "cancelled-parent"
    refute Map.has_key?(state.ai.run_metadata, :deliveries)
  end

  test "a correlated timeout cancels worker B using B's bound identity", %{
    team: team,
    scope: scope
  } do
    Domain.bound_team_assign_task!(
      team,
      %{
        member: :worker,
        task_id: "expires",
        timeout_ms: 60_000,
        metadata: %{hold: true},
        payload: %{text: "hold"}
      },
      scope: scope
    )

    assert_receive {:preparing, "worker-B", _, child_work, _}, 5_000
    monitor = Process.monitor(child_work)

    assert {:ok, attempt} =
             Aikido.AgentServer.state(team.pid, fn runtime ->
               {:ok, runtime.agent.state.team.tasks["expires"].attempt}
             end)

    timeout =
      Aikido.Team.Signals.TaskTimeout.new!(
        %{task_id: "expires", attempt: attempt},
        scope: scope
      )

    assert {:ok, :expired} =
             Aikido.AgentServer.call(team.pid, timeout, fn _runtime -> {:ok, :expired} end)

    state =
      await_state_value(
        team.pid,
        fn runtime ->
          if runtime.agent.state.team.tasks["expires"].status == :failed, do: runtime.agent.state
        end,
        timeout: 5_000
      )

    assert state.team.tasks["expires"].result == :timeout
    assert_receive {:DOWN, ^monitor, :process, ^child_work, _}, 5_000
    worker = state.team.members.worker

    await_state_value(
      worker,
      fn runtime ->
        if runtime.agent.state.ai.status == :failed && is_nil(runtime.agent.state.work.pending),
          do: true
      end,
      timeout: 5_000
    )
  end
end
