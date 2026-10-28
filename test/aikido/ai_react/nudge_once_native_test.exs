defmodule Aikido.AiReact.NudgeOnceNativeTest do
  use AikidoTest.Atl47Native.Case, async: false

  test "one bare final receives one reminder and a second settles the named obligation without another request",
       ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    request_id = ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("I have delivered"))
    assert_receive {:atl47_model, second, :lead, messages, _}, 5_000
    assert text(messages) =~ "work"
    assert text(messages) =~ "Provide evidence"
    assert {:ok, reminded} = ai(owner)
    assert reminded.request_id == request_id
    assert reminded.todo_idle_reminder.iteration == 1
    respond(second, Responses.final_answer_response("I have already delivered"))
    failed = await_ai(owner, &(&1.status == :failed))

    assert %Aikido.AiReact.Errors.CompletedUnclosed{
             todos: [%{id: "work", text: "Provide evidence for work"}]
           } = failed.error

    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "an actual held native ToolExec clears the reminder while preserving caller and deadline",
       ctx do
    owner = start_owner(ctx, %{}, %{tools: [:test_wait, :test_identity]})
    require_work(ctx, owner)
    deadline = System.system_time(:millisecond) + 30_000
    request_id = ask_owner(ctx, owner, "use tools", %{aikido_deadline_at: deadline})
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("not yet"))
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    respond(second, Responses.tool_call_response([{"test_wait", %{}}]))
    assert_receive {:tool_running, tool}, 5_000
    assert {:ok, active} = ai(owner)
    assert active.todo_idle_reminder == nil
    assert active.request_id == request_id
    assert active.deadline_at == deadline
    assert active.run_scope.actor == ctx.scope[:actor]
    assert active.run_scope.tenant == ctx.scope[:tenant]
    send(tool, :continue)
    assert_receive {:atl47_model, third, :lead, _, _}, 5_000
    respond(third, Responses.tool_call_response([{"test_identity", %{}}]))
    assert_receive {:tool_scope, "atl47-owner", "atl47-org"}, 5_000
    assert_receive {:atl47_model, fourth, :lead, _, _}, 5_000
    respond(fourth, Responses.final_answer_response("another proposal"))
    assert_receive {:atl47_model, fifth, :lead, _, _}, 5_000
    assert {:ok, fresh} = ai(owner)
    assert fresh.todo_idle_reminder.iteration == 4
    complete_work(ctx, owner)
    respond(fifth, Responses.final_answer_response("recorded evidence"))
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "builtin-only tool responses cannot reset an existing idle window", ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("delivered"))
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    response = Responses.tool_call_response([])
    call = ReqLLM.ToolCall.new_builtin("builtin", "web_search", "{}")

    response = %{
      response
      | message: ReqLLM.Context.assistant("delivered again", tool_calls: [call])
    }

    respond(second, response)

    assert %Aikido.AiReact.Errors.CompletedUnclosed{} =
             await_ai(owner, &(&1.status == :failed)).error

    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "empty tool batches cannot reset an existing idle window", ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("delivered"))
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    respond(second, Responses.tool_call_response([]))

    assert %Aikido.AiReact.Errors.CompletedUnclosed{} =
             await_ai(owner, &(&1.status == :failed)).error

    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "a before-tool denial retains the reminder and the native denial cause", ctx do
    hook = %{
      name: "no tools",
      event: :before_tool,
      script: ~s(return {decision = "deny", message = "not authorized"})
    }

    owner = start_owner(ctx, %{}, %{tools: [:test_wait], hooks: [hook]})
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("delivered"))
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    respond(second, Responses.tool_call_response([{"test_wait", %{}}]))
    failed = await_ai(owner, &(&1.status == :failed))
    assert failed.error == {:hook_denied, "no tools", "not authorized"}
    assert failed.todo_idle_reminder.iteration == 1
    refute_received {:tool_running, _}
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "a changed obligation revision receives a new window rather than a second-final failure",
       ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    assert {:ok, before} = ai(owner)
    require_work(ctx, owner, "new-obligation")
    respond(second, Responses.final_answer_response("different requirement set"))
    assert_receive {:atl47_model, third, :lead, _, _}, 5_000
    assert {:ok, after_change} = ai(owner)
    assert after_change.todo_idle_reminder.revision != before.todo_idle_reminder.revision
    assert after_change.todo_idle_reminder.iteration == 2
    complete_work(ctx, owner)
    complete_work(ctx, owner, "new-obligation")
    respond(third, Responses.final_answer_response("all recorded"))
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "a real generic todo notification cannot count as another accepted model final", ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    response = Responses.final_answer_response("first")
    respond(first, response)
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    assert {:ok, before} = ai(owner)

    duplicate =
      Aikido.AiReact.Signals.LlmTurn.new!(
        %{
          request_id: before.request_id,
          iteration: before.iteration,
          turn: response
        },
        scope: Map.new(ctx.scope)
      )

    assert {:ok, :ignored_duplicate} =
             Aikido.AgentServer.call(owner.pid, duplicate, fn _ -> {:ok, :ignored_duplicate} end)

    assert {:ok, ^before} = ai(owner)
    signal = Aikido.Todo.Signals.TodoChanged.new!(%{}, scope: Map.new(ctx.scope))

    assert {:ok, :observed} =
             Aikido.AgentServer.call(owner.pid, signal, fn _ -> {:ok, :observed} end)

    assert {:ok, unchanged} = ai(owner)
    assert unchanged.todo_idle_reminder == before.todo_idle_reminder
    assert unchanged.status == :running
    refute_received {:atl47_model, _, :lead, _, _}
    complete_work(ctx, owner)
    respond(second, Responses.final_answer_response("done"))
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "wait policy remains parked without a reminder", ctx do
    owner = start_owner(ctx, %{todo_continuation: :wait})
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("waiting"))
    waiting = await_ai(owner, &(&1.status == :waiting))
    assert waiting.todo_idle_reminder == nil
    refute_received {:atl47_model, _, :lead, _, _}
    complete_work(ctx, owner)
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "first-reminder iteration exhaustion preserves its genuine bound", ctx do
    owner = start_owner(ctx, %{}, %{max_iterations: 1})
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("still open"))
    failed = await_ai(owner, &(&1.status == :failed))
    assert failed.error == {:todo_continuation_limit, 0}
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "real tool activity can exhaust the continuation bound without becoming completed-unclosed",
       ctx do
    owner = start_owner(ctx, %{max_todo_continuations: 1}, %{tools: [:test_wait]})
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    respond(second, Responses.tool_call_response([{"test_wait", %{}}]))
    assert_receive {:tool_running, tool}, 5_000
    send(tool, :continue)
    assert_receive {:atl47_model, third, :lead, _, _}, 5_000
    respond(third, Responses.final_answer_response("productive attempt but still open"))
    failed = await_ai(owner, &(&1.status == :failed))
    assert failed.error == {:todo_continuation_limit, 1}
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "a held reminder request keeps its real shared deadline failure", ctx do
    owner = start_owner(ctx, %{model_timeout_ms: 30_000})
    require_work(ctx, owner)
    deadline = System.system_time(:millisecond) + 1_000
    ask_owner(ctx, owner, "finish within budget", %{aikido_deadline_at: deadline})
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_model, held, :lead, _, _}, 5_000
    monitor = Process.monitor(held)
    failed = await_ai(owner, &(&1.status == :failed))
    assert failed.error == :timeout
    assert failed.deadline_at == deadline
    assert_receive {:DOWN, ^monitor, :process, ^held, _}, 5_000
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "cancellation of a held reminder keeps cancellation instead of completed-unclosed", ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_model, held, :lead, _, _}, 5_000
    monitor = Process.monitor(held)
    owner_command!(ctx, owner, :cancel, %{})
    failed = await_ai(owner, &(&1.status == :failed))
    assert failed.error == :cancelled
    assert_receive {:DOWN, ^monitor, :process, ^held, _}, 5_000
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "checkpoint and saved restoration clear the window without resuming interrupted work",
       ctx do
    owner = start_owner(ctx)
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_model, _held, :lead, _, _}, 5_000
    assert {:ok, active} = ai(owner)
    assert active.todo_idle_reminder != nil
    wrapper = :sys.get_state(owner.pid).user_state

    saved =
      wrapper
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

    assert {:agent, persisted} = saved.agent
    assert persisted.state.ai.todo_idle_reminder == nil
    owner_command!(ctx, owner, :stop, %{})
    restored = command!(Atl47Native.Agent, :start, %{id: owner.id}, ctx.scope)
    assert {:ok, interrupted} = ai(restored)
    assert interrupted.status == :failed
    assert interrupted.error == :interrupted
    assert interrupted.todo_idle_reminder == nil
    refute_received {:atl47_model, _, :lead, _, _}
    ask_owner(ctx, restored, "retry explicitly")
    assert_receive {:atl47_model, next, :lead, _, _}, 5_000
    respond(next, Responses.final_answer_response("new proposal"))
    assert_receive {:atl47_model, resumed, :lead, _, _}, 5_000
    assert {:ok, reminded} = ai(restored)
    assert reminded.todo_idle_reminder.iteration == 1
    complete_work(ctx, restored)
    respond(resumed, Responses.final_answer_response("recorded"))
    assert :completed == await_ai(restored, &(&1.status == :completed)).status
  end

  for hold_activation <- [false, true] do
    test "own background work protects the idle window while #{if hold_activation, do: "activation", else: "worker"} is pending",
         ctx do
      owner = start_owner(ctx)
      require_work(ctx, owner)

      owner_command!(ctx, owner, :add_member, %{
        member: "worker",
        template: :worker,
        activation: :lazy,
        initial_state: %{
          model: "offline",
          client: Atl47Native.Client,
          llm_opts: [observer: self(), label: :worker],
          tools: [],
          hold_activation: unquote(hold_activation),
          activation_observer: self()
        }
      })

      ask_owner(ctx, owner)
      assert_receive {:atl47_model, lead, :lead, _, _}, 5_000

      owner_command!(ctx, owner, :assign_task, %{
        member: "worker",
        task_id: "background",
        payload: %{text: "gather evidence"},
        requester: :self,
        notify: :self,
        mode: :background,
        timeout_ms: 30_000
      })

      if unquote(hold_activation) do
        assert_receive {:atl47_activation, activation}, 5_000
        respond(lead, Responses.final_answer_response("waiting for worker"))
        waiting = await_ai(owner, &(&1.status == :waiting))
        assert waiting.todo_idle_reminder == nil
        refute_received {:atl47_model, _, :lead, _, _}
        send(activation, :activate_worker)
      end

      assert_receive {:atl47_model, worker, :worker, _, _}, 5_000

      unless unquote(hold_activation) do
        respond(lead, Responses.final_answer_response("waiting for worker"))
        waiting = await_ai(owner, &(&1.status == :waiting))
        assert waiting.todo_idle_reminder == nil
        refute_received {:atl47_model, _, :lead, _, _}
      end

      respond(worker, Responses.final_answer_response("worker evidence"))
      assert_receive {:atl47_model, resumed, :lead, messages, _}, 5_000
      assert text(messages) =~ "worker evidence"
      complete_work(ctx, owner)
      respond(resumed, Responses.final_answer_response("checked worker evidence"))
      assert :completed == await_ai(owner, &(&1.status == :completed)).status
    end
  end
end
