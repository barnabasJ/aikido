defmodule Aikido.AiReact.ModelPreparationTest do
  use AikidoTest.Case, async: false
  alias Aikido.ModelPreparationTest.{Authority, Domain, Preparation}
  alias Aikido.AI.Test.ResponseFixtures, as: Responses
  alias Aikido.AttemptTimingTest.Manual

  setup do
    receiver = %{id: unique_id("receiver"), allowed: true, can_prepare?: true, observer: self()}
    sender = %{id: unique_id("sender"), allowed: true, can_prepare?: false, observer: self()}

    receiver_scope = %{
      actor: receiver,
      tenant: "receiver-org",
      context: %{private_history: "startup-private", aikido: %{metadata: %{profile: "foreign"}}}
    }

    sender_scope = %{
      actor: sender,
      tenant: "sender-org",
      context: %{
        private_history: "sender-private",
        aikido: %{agent_id: "foreign", metadata: %{profile: "foreign"}}
      }
    }

    start_supervised!({Authority, [receiver_scope, sender_scope]})
    options = Keyword.put(durable_options(), :scope_adapter, Authority)
    start_supervised!({Aikido, name: Aikido.Default, durable: options})

    %{
      receiver: receiver,
      sender: sender,
      receiver_scope: receiver_scope,
      sender_scope: sender_scope
    }
  end

  test "preparation uses the bound receiver and own metadata without persisting provider options",
       ctx do
    worker = start_worker(ctx.receiver_scope)

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.worker_ask(worker, %{query: "wrong caller", request_id: "foreign"},
               scope: ctx.sender_scope,
               context: ctx.sender_scope.context
             )

    refute_receive {:model_preparing, _, _, _, _, _}

    Domain.worker_ask!(
      worker,
      %{
        query: "private conversation history",
        request_id: "direct",
        metadata: %{profile: "foreign", private_history: "run-private"}
      },
      scope: ctx.receiver_scope,
      context: ctx.sender_scope.context
    )

    assert_receive {:model_preparing, _attempt, actor, tenant, context, arguments}, 5_000
    assert actor == ctx.receiver
    assert tenant == "receiver-org"

    assert context.aikido == %{
             agent_id: worker.id,
             agent_resource: Aikido.ModelPreparationTest.Worker,
             aikido: Aikido.Default,
             partition: nil,
             metadata: %{profile: "receiver"}
           }

    refute Map.has_key?(context, :private_history)

    assert {:ok, {"startup-private", run_scope}} =
             Aikido.AgentServer.state(worker.pid, fn runtime ->
               {:ok,
                {runtime.bound_execution_scope.context.private_history,
                 runtime.agent.state.ai.run_scope}}
             end)

    assert run_scope == %{actor: ctx.receiver, tenant: "receiver-org"}

    assert Enum.sort(Map.keys(arguments)) == [:model, :options]
    assert arguments.model == "offline:original"
    refute inspect(arguments) =~ "private conversation history"
    refute inspect(arguments) =~ "run-private"

    assert_receive {:provider_called, provider, "prepared:receiver", _messages, options}, 5_000
    assert is_binary(options[:api_key])
    assert options[:max_tokens] == 64
    send(provider, {:provider_result, {:ok, Responses.final_answer_response("done")}})
    ai = await_terminal(worker, "direct")
    assert ai.status == :completed
    assert ai.model == "offline:original"
    assert ai.llm_opts == [max_tokens: 64]
    refute inspect(ai, limit: :infinity) =~ options[:api_key]
    refute inspect(saved(worker), limit: :infinity) =~ options[:api_key]
  end

  test "resource preparation survives retained nil options and ignores mutable callback overrides",
       ctx do
    worker =
      Domain.configured_worker_start!(
        %{
          id: unique_id("configured-worker"),
          actor_id: ctx.receiver.id,
          metadata: %{profile: "receiver"},
          llm_opts: [max_tokens: 64],
          options: %{model_preparation: nil, model_timeout_ms: 7_301, model_max_retries: 0}
        },
        scope: ctx.receiver_scope,
        context: ctx.receiver_scope.context
      )

    assert Aikido.AI.Info.ai_model_preparation!(worker.resource) == {Preparation, :prepare}

    assert {:ok, %{model_preparation: nil, model_timeout_ms: 7_301}} =
             Aikido.AgentServer.state(worker.pid, &{:ok, &1.agent.state.ai.options})

    Domain.configured_worker_stop!(worker, scope: ctx.receiver_scope)

    restored =
      Domain.configured_worker_start!(
        %{
          id: worker.id,
          actor_id: ctx.receiver.id,
          options: %{model_preparation: {Preparation, :invalid}, model_timeout_ms: 20}
        },
        scope: ctx.receiver_scope,
        context: ctx.receiver_scope.context
      )

    assert {:ok, %{model_preparation: nil, model_timeout_ms: 7_301}} =
             Aikido.AgentServer.state(restored.pid, &{:ok, &1.agent.state.ai.options})

    Domain.configured_worker_ask!(
      restored,
      %{query: "restored config", request_id: "source-config"},
      scope: ctx.receiver_scope,
      context: ctx.sender_scope.context
    )

    assert_receive {:model_preparing, _, actor, _, context, _}, 5_000
    assert actor == ctx.receiver
    assert context.aikido.agent_resource == Aikido.ModelPreparationTest.WorkerConfigured
    assert_receive {:provider_called, provider, "prepared:receiver", _, options}, 5_000
    send(provider, {:provider_result, {:ok, Responses.final_answer_response("configured")}})
    retained = await_terminal(restored, "source-config")
    assert retained.options.model_preparation == nil
    assert retained.options.model_timeout_ms == 7_301
    refute inspect(saved(restored), limit: :infinity) =~ options[:api_key]

    overridden =
      retained.options
      |> Map.from_struct()
      |> Map.put(:model_preparation, {Preparation, :invalid})

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(restored.pid, "per-request override",
          scope: ctx.receiver_scope,
          context: ctx.sender_scope.context,
          options: overridden
        )
      end)

    assert_receive {:model_preparing, _, _, _, _, _}, 5_000
    assert_receive {:provider_called, next, "prepared:receiver", _, _}, 5_000

    send(
      next,
      {:provider_result, {:ok, Responses.final_answer_response("source owns preparation")}}
    )

    assert {:ok, "source owns preparation"} = Task.await(task, 5_000)

    assert {:ok, current} =
             Aikido.AgentServer.state(restored.pid, &{:ok, &1.agent.state.ai.options})

    assert current.model_preparation == {Preparation, :invalid}
    assert current.model_timeout_ms == 7_301
  end

  test "each retried provider attempt prepares transient credentials again", ctx do
    worker =
      start_worker(ctx.receiver_scope, options: %{model_max_retries: 1, retry_backoff_ms: 1})

    Domain.worker_ask!(worker, %{query: "retry", request_id: "retry"},
      scope: ctx.receiver_scope,
      context: ctx.sender_scope.context
    )

    assert_receive {:model_preparing, _, _, _, _, _}, 5_000
    assert_receive {:provider_called, first, _, _, first_options}, 5_000
    send(first, {:provider_result, {:error, :rate_limited}})
    assert_receive {:model_preparing, _, actor, _, _, _}, 5_000
    assert actor == ctx.receiver
    assert_receive {:provider_called, second, _, _, second_options}, 5_000
    refute second_options[:api_key] == first_options[:api_key]
    send(second, {:provider_result, {:ok, Responses.final_answer_response("retried")}})
    assert await_terminal(worker, "retry").status == :completed
    persisted = inspect(saved(worker), limit: :infinity)
    refute persisted =~ first_options[:api_key]
    refute persisted =~ second_options[:api_key]
  end

  test "native preparation denial and invalid result have finite persisted failures", ctx do
    for {action, secret} <- [
          denied: "private-denied-preparation-secret",
          invalid: "private-invalid-return-secret"
        ] do
      worker =
        start_worker(ctx.receiver_scope, options: %{model_preparation: {Preparation, action}})

      Domain.worker_ask!(worker, %{query: "must fail safely", request_id: "#{action}"},
        scope: ctx.receiver_scope,
        context: ctx.sender_scope.context
      )

      ai = await_terminal(worker, "#{action}")
      assert ai.status == :failed

      assert %Aikido.AiReact.Errors.ModelPreparationFailed{resource: Preparation, action: ^action} =
               ai.error

      assert AshLua.Error.to_error(ai.error).code == "model_preparation_failed"
      assert is_binary(AshAi.ToToolError.to_tool_error(ai.error))
      refute inspect(ai.error, limit: :infinity) =~ secret
      refute Exception.message(ai.error) =~ secret
      refute inspect(saved(worker), limit: :infinity) =~ secret
      refute_receive {:provider_called, _, _, _, _}
    end
  end

  test "cancellation retires blocked preparation before provider I/O", ctx do
    worker = start_worker(ctx.receiver_scope, metadata: %{profile: "receiver", hold?: true})

    Domain.worker_ask!(worker, %{query: "cancel", request_id: "cancel"},
      scope: ctx.receiver_scope,
      context: ctx.sender_scope.context
    )

    assert_receive {:model_preparing, attempt, _, _, _, _}, 5_000
    monitor = Process.monitor(attempt)
    Domain.worker_cancel!(worker, %{request_id: "cancel"}, scope: ctx.receiver_scope)
    assert await_terminal(worker, "cancel").error == :cancelled
    assert_receive {:DOWN, ^monitor, :process, ^attempt, _}, 5_000
    refute_receive {:provider_called, _, _, _, _}
  end

  test "the existing attempt deadline also covers blocked native preparation", ctx do
    clock = start_supervised!({Manual, self()})
    scope = put_in(ctx.receiver_scope, [:context, :aikido_attempt_timing], {Manual, clock})

    worker =
      start_worker(scope,
        metadata: %{profile: "receiver", hold?: true},
        options: %{model_timeout_ms: 50}
      )

    Domain.worker_ask!(worker, %{query: "deadline", request_id: "deadline"},
      scope: scope,
      context: scope.context
    )

    assert_receive {:model_preparing, attempt, _, _, context, _}, 5_000
    refute Map.has_key?(context, :aikido_attempt_timing)
    monitor = Process.monitor(attempt)
    assert_receive {:armed, _, _, 50}, 5_000
    :ok = Manual.advance(clock, 50)
    assert await_terminal(worker, "deadline").error == :timeout
    assert_receive {:DOWN, ^monitor, :process, ^attempt, _}, 5_000
    refute_receive {:provider_called, _, _, _, _}
  end

  test "a delegated RunTask and a restored worker prepare as the receiver", ctx do
    team =
      Domain.team_start!(
        %{
          id: unique_id("team"),
          actor_id: ctx.sender.id,
          topology: %{
            worker: %{
              resource: Aikido.ModelPreparationTest.Worker,
              initial_state: %{actor_id: ctx.receiver.id, metadata: %{profile: "receiver"}},
              activation: :eager
            }
          }
        },
        scope: ctx.sender_scope,
        context: ctx.sender_scope.context
      )

    assert_delegated_preparation(team, "delegated", ctx)

    assert {:ok, old_worker} =
             Aikido.AgentServer.state(team.pid, &{:ok, &1.agent.state.team.members.worker})

    Domain.team_stop!(team, scope: ctx.sender_scope)
    AikidoTest.LifecycleWait.await_down(old_worker, 5_000)

    restored =
      Domain.team_start!(%{id: team.id, actor_id: ctx.sender.id},
        scope: ctx.sender_scope,
        context: ctx.sender_scope.context
      )

    Domain.team_reconcile!(restored, %{}, scope: ctx.sender_scope)
    assert_delegated_preparation(restored, "restored-delegation", ctx)
  end

  defp assert_delegated_preparation(team, task_id, ctx) do
    Domain.team_assign_task!(
      team,
      %{
        member: :worker,
        task_id: task_id,
        payload: %{text: "delegated task", metadata: %{profile: "foreign"}}
      },
      scope: ctx.sender_scope,
      context: ctx.sender_scope.context
    )

    assert_receive {:model_preparing, _, actor, tenant, context, _}, 5_000
    assert actor == ctx.receiver
    assert tenant == "receiver-org"
    assert context.aikido.agent_id == "#{team.id}/worker"
    assert context.aikido.metadata == %{profile: "receiver"}
    assert_receive {:provider_called, provider, "prepared:receiver", _, _}, 5_000
    send(provider, {:provider_result, {:ok, Responses.final_answer_response("delegated")}})

    state =
      await_state_value(
        team.pid,
        fn runtime ->
          task = runtime.agent.state.team.tasks[task_id]
          if task && task.status == :completed, do: task
        end,
        timeout: 5_000
      )

    assert state.status == :completed
  end

  defp start_worker(scope, overrides \\ []) do
    :ok = Authority.register(scope)

    options =
      Map.merge(
        %{model_preparation: {Preparation, :prepare}, model_max_retries: 0},
        Keyword.get(overrides, :options, %{})
      )

    Domain.worker_start!(
      %{
        id: Keyword.get(overrides, :id, unique_id("worker")),
        actor_id: scope.actor.id,
        metadata: Keyword.get(overrides, :metadata, %{profile: "receiver"}),
        llm_opts: [max_tokens: 64],
        options: options
      },
      scope: scope,
      context: scope.context
    )
  end

  defp await_terminal(worker, request) do
    await_state_value(
      worker.pid,
      fn runtime ->
        ai = runtime.agent.state.ai
        if ai.request_id == request && ai.status in [:completed, :failed], do: ai
      end,
      timeout: 5_000
    )
  end

  defp saved(worker) do
    worker.pid
    |> :sys.get_state()
    |> Map.fetch!(:user_state)
    |> Aikido.Durable.AgentServer.dump_state()
    |> then(&Aikido.Durable.AgentServer.load_state(2, &1))
  end
end
