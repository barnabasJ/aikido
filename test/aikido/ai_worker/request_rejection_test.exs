defmodule Aikido.AiWorker.RequestRejectionTest do
  use AikidoTest.Case, async: true

  @moduletag aikido_instance: Aikido.WorkerRequestRejectionTest.Instance,
             aikido_scope_adapter: Aikido.WorkerRequestRejectionTest.Authority
  alias Aikido.WorkerRequestRejectionTest.{Access, Authority, Domain, Worker}
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  setup do
    Process.register(self(), Aikido.WorkerRequestRejectionTest.Observer)
    owner = %{id: unique_id("owner"), allowed: true, observer: self()}
    worker = %{id: unique_id("worker"), allowed: true, observer: self()}
    start_supervised!({Authority, [scope(owner), scope(worker)]})
    access = Ash.create!(Access, %{id: worker.id}, authorize?: false)

    team =
      Domain.team_start!(
        %{
          id: unique_id("rejection-team"),
          actor_id: owner.id,
          topology: %{worker: %{resource: Worker, initial_state: %{actor_id: worker.id}}}
        },
        scope: scope(owner)
      )

    assert {:ok, pid} =
             Aikido.AgentServer.state(team.pid, &{:ok, &1.agent.state.team.members.worker})

    %{team: team, worker: pid, owner: owner, receiver: worker, access: access}
  end

  test "confirmed Ask denial settles its accepted task and the queued successor still runs",
       ctx do
    revoked = Ash.update!(ctx.access, %{active?: false}, authorize?: false)
    assign(ctx, "denied", "must not reach provider")
    assert_receive {:worker_ask_denied, blocked_worker}, 5_000
    assert blocked_worker == ctx.worker
    on_exit(fn -> send(blocked_worker, :release_ask_denial) end)
    assign(ctx, "next", "queued successor")
    Ash.update!(revoked, %{active?: true}, authorize?: false)
    send(blocked_worker, :release_ask_denial)

    failed = await_task(ctx.team, "denied", :failed)
    assert %Aikido.AiWorker.Errors.RequestRejected{failure: :forbidden} = failed.result
    assert AshLua.Error.to_error(failed.result).code == "worker_ai_request_rejected"
    refute inspect(failed, limit: :infinity) =~ "private-worker-model-permission-secret"

    assert_receive {:worker_provider, provider, messages}, 5_000
    refute message_text(messages) =~ "must not reach provider"
    assert message_text(messages) =~ "queued successor"

    assert {:ok, "next"} =
             Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.ai.request_id})

    send(provider, {:provider_result, {:ok, Responses.final_answer_response("done")}})
    assert await_task(ctx.team, "next", :completed).result == "done"

    assert {:ok, %{pending: nil, completed: 2}} =
             Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.work})

    refute_receive {:worker_provider, _, _}
  end

  test "stale, duplicate and post-adoption rejection reports cannot settle another request",
       ctx do
    assign(ctx, "live", "admitted run")
    assert_receive {:worker_provider, provider, _messages}, 5_000

    assert {:ok, pending} =
             Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.work.pending})

    for change <- [%{task_id: "old"}, %{member: :other}, %{attempt: "old-incarnation"}, %{}] do
      rejection =
        pending
        |> Map.take([:task_id, :member, :attempt])
        |> Map.merge(change)
        |> Map.put(:failure, :forbidden)
        |> Aikido.AiWorker.Signals.RequestRejected.new!(scope: scope(ctx.receiver))

      assert {:ok, ^pending} =
               Aikido.AgentServer.call(ctx.worker, rejection, &{:ok, &1.agent.state.work.pending})
    end

    assert {:ok, :dispatched} =
             Aikido.AgentServer.state(
               ctx.team.pid,
               &{:ok, &1.agent.state.team.tasks["live"].status}
             )

    send(provider, {:provider_result, {:ok, Responses.final_answer_response("live result")}})
    await_task(ctx.team, "live", :completed)

    duplicate =
      pending
      |> Map.take([:task_id, :member, :attempt])
      |> Map.put(:failure, :invalid)
      |> Aikido.AiWorker.Signals.RequestRejected.new!(scope: scope(ctx.receiver))

    assert {:ok, 1} =
             Aikido.AgentServer.call(ctx.worker, duplicate, &{:ok, &1.agent.state.work.completed})
  end

  test "rejection preserves queued work while an unrelated AI run is active", ctx do
    revoked = Ash.update!(ctx.access, %{active?: false}, authorize?: false)
    assign(ctx, "denied", "rejected assignment")
    assert_receive {:worker_ask_denied, blocked_worker}, 5_000
    on_exit(fn -> send(blocked_worker, :release_ask_denial) end)
    assign(ctx, "queued", "queued after manual run")
    Ash.update!(revoked, %{active?: true}, authorize?: false)

    manual =
      Aikido.AiReact.Signals.Ask.new!(
        %{query: "unrelated manual run", request_id: "manual"},
        scope: scope(ctx.receiver)
      )

    :ok = Aikido.AgentServer.cast(ctx.worker, manual)
    send(blocked_worker, :release_ask_denial)

    await_task(ctx.team, "denied", :failed)
    assert_receive {:worker_provider, manual_provider, messages}, 5_000
    assert message_text(messages) =~ "unrelated manual run"

    assert {:ok, %{pending: nil, queue: [%{task_id: "queued"}]}} =
             Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.work})

    assert {:ok, "manual"} =
             Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.ai.request_id})

    refute_receive {:worker_provider, _, _}

    send(
      manual_provider,
      {:provider_result, {:ok, Responses.final_answer_response("manual done")}}
    )

    assert_receive {:worker_provider, queued_provider, queued_messages}, 5_000
    assert message_text(queued_messages) =~ "queued after manual run"

    assert {:ok, "queued"} =
             Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.ai.request_id})

    send(
      queued_provider,
      {:provider_result, {:ok, Responses.final_answer_response("queued done")}}
    )

    assert await_task(ctx.team, "queued", :completed).result == "queued done"
  end

  test "a delegated Ask materializes its envelope before application journal middleware", ctx do
    metadata = %{display: "preserved task metadata"}

    Domain.team_assign_task!(
      ctx.team,
      %{
        member: :worker,
        task_id: "envelope",
        metadata: metadata,
        payload: %{text: "materialized task payload"}
      },
      scope: scope(ctx.owner)
    )

    assert_receive {:worker_ask_envelope, worker, ask, journal_id}, 5_000
    assert worker == ctx.worker
    assert is_binary(ask.id)
    assert ask.id != ""
    assert journal_id == ask.id <> "/journal"
    assert {:ok, _, _} = DateTime.from_iso8601(ask.time)
    assert ask.data.request_id == "envelope"
    assert ask.data.query == "materialized task payload"
    assert ask.data.metadata == metadata
    assert ask.scope.actor == ctx.receiver
    assert ask.scope.tenant == "request-rejection"
    assert_receive {:worker_provider, provider, _messages}, 5_000
    send(provider, {:provider_result, {:ok, Responses.final_answer_response("materialized")}})
    assert await_task(ctx.team, "envelope", :completed).result == "materialized"
  end

  test "native request processing preserves an existing envelope and its scope and trace metadata",
       ctx do
    tracer = Aikido.WorkerRequestRejectionTest.Tracer

    scope =
      Map.merge(scope(ctx.receiver), %{
        context: %{marker: "original application context"},
        tracer: [tracer]
      })

    ask =
      Aikido.AiReact.Signals.Ask.new!(
        %{
          query: "supplied envelope",
          request_id: "supplied",
          metadata: %{display: "caller metadata"}
        },
        id: "supplied-envelope-id",
        time: "2026-11-04T10:11:12.000000Z",
        source: "/application",
        subject: "original-subject",
        scope: scope,
        tracer_context: %{tracer => :original_ancestry}
      )

    assert {:signals, []} =
             Aikido.AiWorker.RequestAdmission.request(ctx.worker, ask, %{
               task_id: "supplied",
               member: :worker,
               attempt: "supplied-attempt"
             })

    assert_receive {:worker_ask_envelope, worker, received, journal_id}, 5_000
    assert worker == ctx.worker
    assert received.id == ask.id
    assert received.time == ask.time
    assert received.source == ask.source
    assert received.subject == ask.subject
    assert received.data == ask.data
    assert received.scope == ask.scope
    assert received.tracer_context == ask.tracer_context
    assert journal_id == ask.id <> "/journal"
    assert_receive {:worker_provider, provider, _messages}, 5_000
    send(provider, {:provider_result, {:ok, Responses.final_answer_response("preserved")}})

    await_state_value(ctx.worker, fn runtime ->
      ai = runtime.agent.state.ai
      if ai.request_id == "supplied" && ai.status == :completed, do: ai
    end)
  end

  test "an invalid envelope produces finite invalid rejection before delivery", ctx do
    # Deliberately malformed native envelope exercises the I/O input-rejection boundary.
    ask =
      Aikido.AiReact.Signals.Ask.new!(
        %{query: "private-invalid-envelope-payload", request_id: "invalid"},
        scope: scope(ctx.receiver)
      )

    for malformed <- [%{type: nil}, %{scope: nil}] do
      invalid = Map.merge(ask, malformed)

      assert %Aikido.Signal{type: "harness.ai.request_rejected", data: data, scope: %{}} =
               result =
               Aikido.AiWorker.RequestAdmission.request(ctx.worker, invalid, %{
                 task_id: "invalid",
                 member: :worker,
                 attempt: "invalid-attempt"
               })

      assert result.scope == %{}

      assert data == %{
               task_id: "invalid",
               member: :worker,
               attempt: "invalid-attempt",
               failure: :invalid
             }

      refute inspect(result, limit: :infinity) =~ "private-invalid-envelope-payload"
    end

    refute_receive {:worker_ask_envelope, _, _, _}
    refute_receive {:worker_provider, _, _}
    assert {:ok, nil} = Aikido.AgentServer.state(ctx.worker, &{:ok, &1.agent.state.ai.request_id})
  end

  test "actual owner loss remains ambiguous rather than reporting admission rejection", ctx do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

    ask =
      Aikido.AiReact.Signals.Ask.new!(
        %{query: "dead target", request_id: "absent"},
        scope: scope(ctx.receiver)
      )

    assert {:signals, []} =
             Aikido.AiWorker.RequestAdmission.request(pid, ask, %{
               task_id: "absent",
               member: :worker,
               attempt: "absent-attempt"
             })

    refute_receive {:worker_ask_envelope, _, _, _}
    refute_receive {:worker_provider, _, _}
  end

  defp scope(actor), do: %{actor: actor, tenant: "request-rejection"}

  defp message_text(messages),
    do: messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", &(&1.text || ""))

  defp assign(ctx, id, text) do
    Domain.team_assign_task!(ctx.team, %{member: :worker, task_id: id, payload: %{text: text}},
      scope: scope(ctx.owner)
    )
  end

  defp await_task(team, id, status) do
    await_state_value(team.pid, fn runtime ->
      case runtime.agent.state.team.tasks[id] do
        %{status: ^status} = task -> task
        _ -> nil
      end
    end)
  end
end
