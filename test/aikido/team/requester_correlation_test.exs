defmodule Aikido.RequesterCorrelationTest do
  use AikidoTest.Case, async: true
  alias Aikido.RequesterCorrelationTest.{Domain, FailingWorker, Requester, Worker}
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  @moduletag aikido_instance: Aikido.RequesterCorrelationTest.Instance,
             aikido_scope_adapter: Aikido.TeamMemberAdmissionTest.Authority

  setup do
    Process.register(self(), Aikido.RequesterCorrelationTest.Observer)
    owner = actor(true)
    requester_actor = actor()
    worker_actor = actor()

    root =
      Domain.coordinator_start!(
        %{
          id: Ash.UUIDv7.generate(),
          actor_id: owner.id,
          topology: %{
            requester: %{resource: Requester, initial_state: %{actor_id: requester_actor.id}},
            worker: %{resource: Worker, initial_state: %{actor_id: worker_actor.id}}
          }
        },
        scope: scope(owner)
      )

    members = state(root.pid).team.members

    {:ok,
     root: root,
     requester: members.requester,
     worker: members.worker,
     owner: owner,
     requester_actor: requester_actor,
     worker_actor: worker_actor}
  end

  test "pure requester correlation rejects coordinator claims and preserves valid named recipients" do
    data = %{requester_request_id: "caller-correlation"}

    for requester <- [nil, :self] do
      task =
        Aikido.Team.TaskDelivery.bind_requester_run(
          %{requester: requester, notify: :member},
          data
        )

      assert task.recipient_request_id == nil
      refute task.recipient_active?
    end

    for notify <- [nil, :member] do
      task =
        Aikido.Team.TaskDelivery.bind_requester_run(%{requester: :member, notify: notify}, data)

      assert task.recipient_request_id == "caller-correlation"
      assert task.recipient_active?
    end

    wrong_recipient =
      Aikido.Team.TaskDelivery.bind_requester_run(%{requester: :member, notify: :other}, data)

    assert wrong_recipient.recipient_request_id == nil
    refute wrong_recipient.recipient_active?
    named = Aikido.Team.TaskDelivery.bind_requester_run(%{requester: false, notify: false}, data)
    assert named.recipient_request_id == "caller-correlation"
    assert named.recipient_active?

    captured = %{
      requester: nil,
      notify: :self,
      recipient_request_id: "actual-native-run",
      recipient_active?: true
    }

    assert Aikido.Team.TaskDelivery.bind_requester_run(captured, data) == captured

    assert Aikido.Team.TaskDelivery.notification_recipient(%{requester: false, mode: :background}) ==
             false

    assert Aikido.Team.TaskDelivery.notification_recipient(%{requester: :member, notify: false}) ==
             false

    assert Aikido.Team.TaskDelivery.notification_recipient(%{
             requester: :member,
             mode: :foreground
           }) == nil
  end

  for mode <- [:foreground, :background] do
    test "a #{mode} sibling completion resumes the actual waiting requester run", ctx do
      request_id = wait_for_answer(ctx)
      id = assign(ctx, unquote(mode), request_id)
      task = state(ctx.root.pid).team.tasks[id]
      assert task.recipient_request_id == request_id
      assert task.recipient_active?
      Domain.worker_finish!(ctx.worker, %{}, scope: scope(ctx.worker_actor))
      assert_receive {:requester_model, resumed, _messages}, 5_000
      assert ai(ctx.requester).request_id == request_id
      assert ai(ctx.requester).run_scope.actor == ctx.requester_actor
      assert state(ctx.root.pid).team.tasks[id].status == :completed
      finish_requester(ctx, resumed)
    end
  end

  test "backgrounding a foreground task preserves its original requester run correlation", ctx do
    request_id = wait_for_answer(ctx)
    id = assign(ctx, :foreground, request_id)
    Domain.coordinator_background_task!(ctx.root, %{task_id: id}, scope: scope(ctx.owner))
    task = state(ctx.root.pid).team.tasks[id]
    assert task.mode == :background
    assert task.recipient_request_id == request_id
    assert task.recipient_active?
    Domain.worker_finish!(ctx.worker, %{}, scope: scope(ctx.worker_actor))
    assert_receive {:requester_model, resumed, _}, 5_000
    finish_requester(ctx, resumed)
  end

  test "a stale caller-supplied run identifier cannot resume the right AI under the wrong run",
       ctx do
    request_id = wait_for_answer(ctx)
    id = assign(ctx, :background, "stale-run")
    Domain.worker_finish!(ctx.worker, %{}, scope: scope(ctx.worker_actor))

    await_state_value(ctx.root.pid, fn runtime ->
      if runtime.agent.state.team.tasks[id].status == :completed, do: :completed
    end)

    # Drain the receiving mailbox through its normal native read after the emitted result.
    assert ai(ctx.requester).status == :waiting
    assert ai(ctx.requester).request_id == request_id
    refute ("task-result/" <> id) in ai(ctx.requester).accepted_delivery_ids
    refute_received {:requester_model, _, _}

    Domain.requester_cancel!(ctx.requester, %{request_id: request_id},
      scope: scope(ctx.requester_actor)
    )
  end

  test "an explicit correct run ID does not authorize a foreign sibling principal", ctx do
    request_id = wait_for_answer(ctx)

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.coordinator_assign_task(
               ctx.root,
               %{
                 task_id: Ash.UUIDv7.generate(),
                 member: :worker,
                 requester: :requester,
                 notify: :requester,
                 requester_request_id: request_id,
                 type: "test.member.work",
                 payload: %{result: "forged"}
               },
               scope: scope(ctx.worker_actor)
             )

    assert state(ctx.root.pid).team.tasks == %{}
    assert ai(ctx.requester).status == :waiting

    Domain.requester_cancel!(ctx.requester, %{request_id: request_id},
      scope: scope(ctx.requester_actor)
    )
  end

  test "lazy activation failure preserves correlation and resumes the original waiting requester",
       ctx do
    request_id = wait_for_answer(ctx)

    Domain.coordinator_add_member!(
      ctx.root,
      %{
        member: :failing,
        resource: FailingWorker,
        activation: :lazy,
        initial_state: %{actor_id: ctx.worker_actor.id}
      },
      scope: scope(ctx.owner)
    )

    id = assign(ctx, :background, request_id, :failing)

    task =
      await_state_value(ctx.root.pid, fn runtime ->
        case runtime.agent.state.team.tasks[id] do
          %{status: :failed} = task -> task
          _ -> nil
        end
      end)

    assert task.recipient_request_id == request_id
    assert task.recipient_active?
    assert_receive {:requester_model, resumed, _}, 5_000
    assert ai(ctx.requester).request_id == request_id
    finish_requester(ctx, resumed)
  end

  defp wait_for_answer(ctx) do
    request_id = Ash.UUIDv7.generate()
    todo(ctx, Aikido.Todo.Signals.TodoAdd, %{id: "evidence", text: "Wait for sibling evidence"})

    Domain.requester_ask!(ctx.requester, %{query: "Need evidence", request_id: request_id},
      scope: scope(ctx.requester_actor)
    )

    assert_receive {:requester_model, model, _}, 5_000
    send(model, {:respond, Responses.final_answer_response("Waiting for evidence")})

    waiting =
      await_state_value(ctx.requester, fn runtime ->
        if runtime.agent.state.ai.status == :waiting, do: runtime.agent.state.ai
      end)

    waiting.request_id
  end

  defp finish_requester(ctx, model) do
    send(model, {:respond, Responses.final_answer_response("Evidence received")})
    todo(ctx, Aikido.Todo.Signals.TodoComplete, %{id: "evidence", result: "verified"})

    await_state_value(ctx.requester, fn runtime ->
      if runtime.agent.state.ai.status == :completed, do: :completed
    end)
  end

  defp assign(ctx, mode, request_id, member \\ :worker) do
    id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Domain.coordinator_assign_task(
               ctx.root,
               %{
                 task_id: id,
                 member: member,
                 requester: :requester,
                 notify: :requester,
                 mode: mode,
                 requester_request_id: request_id,
                 type: "test.member.work",
                 payload: %{result: "sibling-evidence", complete?: false}
               },
               scope: scope(ctx.requester_actor)
             )

    if member == :worker do
      await_state_value(ctx.worker, fn runtime ->
        if Aikido.Agent.resource_attributes(runtime.agent).pending_work, do: :ready
      end)
    end

    id
  end

  defp todo(ctx, definition, data) do
    signal = definition.new!(data, scope: scope(ctx.requester_actor))
    assert {:ok, _} = Aikido.AgentServer.call(ctx.requester, signal, &{:ok, &1.agent})
  end

  defp state(pid) do
    assert {:ok, state} =
             Aikido.AgentServer.state(pid, &{:ok, Aikido.Agent.resource_attributes(&1.agent)})

    state
  end

  defp ai(pid), do: state(pid).ai

  defp actor(coordinator? \\ false),
    do: %{id: Ash.UUIDv7.generate(), allowed: true, coordinator?: coordinator?}

  defp scope(actor), do: %{actor: actor, tenant: "requester-correlation"}
end
