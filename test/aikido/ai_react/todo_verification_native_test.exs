defmodule Aikido.AiReact.TodoVerificationNativeTest do
  use AikidoTest.Atl47Native.Case, async: false

  test "an unchanged native boolean verifier receives no optional data argument and keeps its caller scope",
       ctx do
    owner = start_owner(ctx, %{todo_verifier: {Atl47Native.LegacyVerifier, :verify}})
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("verified answer"))
    assert_receive {:atl47_verify, verifier, arguments, actor, tenant}, 5_000
    refute Map.has_key?(arguments, :data)
    assert actor == ctx.scope[:actor]
    assert tenant == ctx.scope[:tenant]
    verdict(verifier, true)
    finished = await_ai(owner, &(&1.status == :completed))
    assert finished.result == "verified answer"
    assert finished.todo_idle_reminder == nil
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "native verifier context identifies the actual receiver instead of configured parent claims",
       ctx do
    claimed = %{
      agent_pid: self(),
      agent_id: "claimed-parent",
      agent_resource: Atl47Native.Worker,
      aikido: :claimed_runtime,
      partition: :claimed_partition,
      request_id: "claimed-request"
    }

    owner =
      start_owner(ctx, verify_options(), %{
        tool_context: %{context: %{observer: self(), aikido: claimed}}
      })

    require_work(ctx, owner)
    request_id = ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal"))
    assert_receive {:atl47_verify, verifier, _, actor, tenant}, 5_000
    assert_receive {:atl47_verifier_context, ^verifier, context}, 5_000
    assert context.aikido.agent_pid == owner.pid
    assert context.aikido.agent_id == owner.id
    assert context.aikido.agent_resource == Atl47Native.Agent
    assert context.aikido.aikido == ctx.instance
    assert context.aikido.partition == nil
    assert context.aikido.request_id == request_id
    assert actor == ctx.scope[:actor]
    assert tenant == ctx.scope[:tenant]
    verdict(verifier, true)
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "native sensitive metadata redacts actual verifier state, signals and directive data",
       ctx do
    alias Aikido.Inspector.History.Redaction
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000

    assert {:ok, signal_subscription} =
             Aikido.AgentServer.subscribe(
               owner.pid,
               "ai.react.todos.verified",
               fn runtime, event ->
                 {:ok,
                  %{
                    state: Redaction.agent_state(runtime.agent.state, runtime.agent_module),
                    signal: Redaction.signal_data(event.signal, runtime.agent_module)
                  }}
               end,
               once: true
             )

    marker = "private-native-verifier-marker"

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(%{accepted?: false, data: %{marker: marker}}, [])
    )

    assert_receive {:atl47_model, second, :lead, _, _}, 5_000

    assert_receive {:aikido_subscription, ^signal_subscription, %{result: {:ok, projected}}},
                   5_000

    refute inspect(projected, limit: :infinity) =~ marker
    assert {:ok, live} = ai(owner)
    assert live.todo_verifier_data == %{marker: marker}

    assert {:ok, directive_subscription} =
             Aikido.AgentServer.subscribe(
               owner.pid,
               "ai.react.llm.completed",
               fn _runtime, event ->
                 {:ok, Redaction.typed_value(event.directives)}
               end,
               once: true
             )

    respond(second, Responses.final_answer_response("recheck"))
    assert_receive {:atl47_verify, verifier, arguments, _, _}, 5_000
    assert arguments.data == %{marker: marker}

    assert_receive {:aikido_subscription, ^directive_subscription, %{result: {:ok, directives}}},
                   5_000

    refute inspect(directives, limit: :infinity) =~ marker
    verdict(verifier, true)
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "typed feedback reaches the model, boolean replies preserve opaque data and typed nil clears it",
       ctx do
    owner = start_owner(ctx, Map.merge(verify_options(), %{todo_continuation: :continue}))
    require_work(ctx, owner)
    deadline = System.system_time(:millisecond) + 30_000
    request_id = ask_owner(ctx, owner, "verify evidence", %{aikido_deadline_at: deadline})
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_verify, verifier, first_args, actor, tenant}, 5_000
    assert first_args.data == nil
    assert first_args.metadata.aikido_deadline_at == deadline
    assert actor == ctx.scope[:actor]
    assert tenant == ctx.scope[:tenant]
    private = %{phase: :fine, marker: "verifier-internal-only"}

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{
          accepted?: false,
          feedback: "Check the recorded evidence",
          data: private
        },
        []
      )
    )

    assert_receive {:atl47_model, second, :lead, messages, _}, 5_000
    assert text(messages) =~ "Check the recorded evidence"
    refute text(messages) =~ "verifier-internal-only"
    assert {:ok, state} = ai(owner)
    assert state.request_id == request_id
    assert state.deadline_at == deadline
    assert state.run_scope.actor == actor
    assert state.run_scope.tenant == tenant
    assert state.todo_verifier_data == private
    respond(second, Responses.final_answer_response("second"))
    assert_receive {:atl47_verify, verifier, second_args, ^actor, ^tenant}, 5_000
    assert second_args.data == private
    verdict(verifier, false)
    assert_receive {:atl47_model, third, :lead, _, _}, 5_000
    respond(third, Responses.final_answer_response("third"))
    assert_receive {:atl47_verify, verifier, third_args, ^actor, ^tenant}, 5_000
    assert third_args.data == private
    verdict(verifier, Aikido.AiReact.TodoVerification.new!(%{accepted?: false, data: nil}, []))
    assert_receive {:atl47_model, fourth, :lead, _, _}, 5_000
    respond(fourth, Responses.final_answer_response("fourth"))
    assert_receive {:atl47_verify, verifier, fourth_args, ^actor, ^tenant}, 5_000
    assert fourth_args.data == nil

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(%{accepted?: true, data: %{accepted: true}}, [])
    )

    assert :completed == await_ai(owner, &(&1.status == :completed)).status
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "a true verdict accepts before the idle guard while false verdicts consume only originating finals",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("proposed"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000
    refute_received {:atl47_model, _, :lead, _, _}

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{accepted?: false, feedback: "One precise repair"},
        []
      )
    )

    assert_receive {:atl47_model, second, :lead, messages, _}, 5_000
    assert text(messages) =~ "One precise repair"
    assert {:ok, reminded} = ai(owner)
    assert reminded.todo_idle_reminder.iteration == 1
    respond(second, Responses.final_answer_response("verified repair"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000
    verdict(verifier, true)
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "a second rejected bare final settles completed-unclosed instead of a third verifier loop",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000
    verdict(verifier, false)
    assert_receive {:atl47_model, second, :lead, _, _}, 5_000
    respond(second, Responses.final_answer_response("second"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000
    verdict(verifier, false)

    assert %Aikido.AiReact.Errors.CompletedUnclosed{todos: [%{id: "work"}]} =
             await_ai(owner, &(&1.status == :failed)).error

    refute_received {:atl47_model, _, :lead, _, _}
    refute_received {:atl47_verify, _, _, _, _}
  end

  test "a typed native verifier error retains its supported blocker and emits no repair request",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("blocked"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000

    cause =
      Ash.Error.Action.InvalidArgument.exception(
        field: :answer,
        message: "Supported irreversible evidence blocker"
      )

    send(verifier, {:verification, {:error, cause}})
    failed = await_ai(owner, &(&1.status == :failed))
    assert is_exception(failed.error)
    assert Exception.message(failed.error) =~ "Supported irreversible evidence blocker"
    refute match?(%Aikido.AiReact.Errors.CompletedUnclosed{}, failed.error)
    assert failed.todo_idle_reminder == nil
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "stale request and iteration results cannot adopt private verifier data or feedback",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    request = ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000

    assert {:ok, revision} =
             Aikido.AgentServer.state(owner.pid, &{:ok, &1.agent.state.todos.revision})

    assert {:ok, before} = ai(owner)

    for {request_id, iteration} <- [
          {"stale-request", before.iteration},
          {request, before.iteration + 1}
        ] do
      stale =
        Aikido.AiReact.Signals.TodosVerified.new!(
          %{
            request_id: request_id,
            iteration: iteration,
            revision: revision,
            final_answer?: true,
            result:
              Aikido.AiReact.TodoVerification.new!(
                %{
                  accepted?: false,
                  feedback: "stale feedback",
                  data: %{poison: true}
                },
                []
              )
          },
          scope: Map.new(ctx.scope)
        )

      assert {:ok, :observed} =
               Aikido.AgentServer.call(owner.pid, stale, fn _ -> {:ok, :observed} end)

      assert {:ok, after_stale} = ai(owner)
      assert after_stale == before
      refute_received {:atl47_model, _, :lead, _, _}
    end

    verdict(verifier, true)
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "a changed todo revision rejects an actual in-flight verifier's data and rechecks current evidence",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal"))
    assert_receive {:atl47_verify, first, _, _, _}, 5_000
    require_work(ctx, owner, "later")

    verdict(
      first,
      Aikido.AiReact.TodoVerification.new!(
        %{
          accepted?: false,
          feedback: "obsolete feedback",
          data: %{stale: true}
        },
        []
      )
    )

    assert_receive {:atl47_verify, second, arguments, _, _}, 5_000
    assert arguments.data == nil
    assert Enum.sort(Enum.map(arguments.todos, & &1.id)) == ["later", "work"]
    assert {:ok, state} = ai(owner)
    assert state.todo_verifier_data == nil
    assert state.todo_idle_reminder == nil
    refute text(state.context.messages) =~ "obsolete feedback"
    verdict(second, true)
    assert :completed == await_ai(owner, &(&1.status == :completed)).status
  end

  test "new asks and checkpoint restoration discard verifier data without leaking it into history",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{
          accepted?: false,
          data: %{marker: "private-verifier-data"}
        },
        []
      )
    )

    assert_receive {:atl47_model, _held, :lead, messages, _}, 5_000
    refute text(messages) =~ "private-verifier-data"
    assert {:ok, live} = ai(owner)
    assert live.todo_verifier_data == %{marker: "private-verifier-data"}
    wrapper = :sys.get_state(owner.pid).user_state

    saved =
      wrapper
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

    assert {:agent, persisted} = saved.agent
    assert persisted.state.ai.todo_verifier_data == nil
    refute inspect(saved, limit: :infinity) =~ "private-verifier-data"
    owner_command!(ctx, owner, :stop, %{})
    restored = command!(Atl47Native.Agent, :start, %{id: owner.id}, ctx.scope)
    assert {:ok, interrupted} = ai(restored)
    assert interrupted.todo_verifier_data == nil
    assert interrupted.error == :interrupted
    ask_owner(ctx, restored, "new run")
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("new proposal"))
    assert_receive {:atl47_verify, verifier, arguments, _, _}, 5_000
    assert arguments.data == nil

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(%{accepted?: true, data: %{previous_run: true}}, [])
    )

    assert :completed == await_ai(restored, &(&1.status == :completed)).status
    ask_owner(ctx, restored, "another new run")
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("another proposal"))
    assert_receive {:atl47_verify, verifier, arguments, _, _}, 5_000
    assert arguments.data == nil
    verdict(verifier, true)
    assert :completed == await_ai(restored, &(&1.status == :completed)).status
  end

  test "invalid structured verifier output fails closed without adopting data or asking again",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000
    verdict(verifier, %{accepted?: %{}, data: %{poison: true}})
    failed = await_ai(owner, &(&1.status == :failed))
    assert inspect(failed.error) =~ "Todo verifier"
    assert failed.todo_verifier_data == nil
    refute_received {:atl47_model, _, :lead, _, _}
  end

  test "a worker result queued during verification invalidates the old verdict and reaches the next model turn",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    request_id = ask_owner(ctx, owner)
    assert_receive {:atl47_model, lead, :lead, _, _}, 5_000
    respond(lead, Responses.final_answer_response("proposal before evidence"))
    assert_receive {:atl47_verify, old_verifier, _, actor, tenant}, 5_000

    owner_command!(ctx, owner, :add_member, %{
      member: "late-worker",
      template: :worker,
      activation: :lazy,
      initial_state: %{
        model: "offline",
        client: Atl47Native.Client,
        llm_opts: [observer: self(), label: :worker],
        tools: []
      }
    })

    owner_command!(ctx, owner, :assign_task, %{
      member: "late-worker",
      task_id: "late-evidence",
      payload: %{text: "gather late evidence"},
      requester: :self,
      notify: :self,
      mode: :background,
      timeout_ms: 30_000
    })

    assert_receive {:atl47_model, worker, :worker, _, _}, 5_000
    respond(worker, Responses.final_answer_response("actual late worker evidence"))
    queued = await_ai(owner, &(&1.todo_verification_pending && &1.queued_messages != []))
    assert queued.request_id == request_id
    assert queued.todo_verifier_data == nil

    verdict(
      old_verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{
          accepted?: true,
          feedback: "obsolete verifier feedback",
          data: %{obsolete: true}
        },
        []
      )
    )

    assert_receive {:atl47_model, resumed, :lead, messages, _}, 5_000
    assert text(messages) =~ "actual late worker evidence"
    refute text(messages) =~ "obsolete verifier feedback"
    assert {:ok, current} = ai(owner)
    assert current.request_id == request_id
    assert current.todo_verifier_data == nil
    assert current.status == :running
    assert current.run_scope.actor == actor
    assert current.run_scope.tenant == tenant
    respond(resumed, Responses.final_answer_response("proposal incorporating late evidence"))
    assert_receive {:atl47_verify, fresh_verifier, arguments, ^actor, ^tenant}, 5_000
    assert arguments.data == nil
    assert arguments.answer == "proposal incorporating late evidence"

    verdict(
      fresh_verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{
          accepted?: true,
          data: %{fresh_evidence: true}
        },
        []
      )
    )

    completed = await_ai(owner, &(&1.status == :completed))
    assert completed.request_id == request_id
    assert completed.result == "proposal incorporating late evidence"
    assert completed.todo_verifier_data == %{fresh_evidence: true}
  end

  test "a native todo blocker takes precedence over queued input and a held stale verifier acceptance",
       ctx do
    owner = start_owner(ctx, verify_options())
    require_work(ctx, owner)
    request_id = ask_owner(ctx, owner)
    assert_receive {:atl47_model, model, :lead, _, _}, 5_000
    respond(model, Responses.final_answer_response("proposal before blocker"))
    assert_receive {:atl47_verify, verifier, _, _, _}, 5_000
    owner_command!(ctx, owner, :todo_block, %{id: "work", reason: :missing_authorized_evidence})
    owner_command!(ctx, owner, :message, %{text: "queued input must not bypass the blocker"})
    pending = await_ai(owner, &(&1.todo_verification_pending && &1.queued_messages != []))
    assert pending.request_id == request_id

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{
          accepted?: true,
          feedback: "obsolete blocked acceptance",
          data: %{blocked_poison: true}
        },
        []
      )
    )

    failed = await_ai(owner, &(&1.status == :failed))
    assert failed.error == {:todo_blocked, "work", :missing_authorized_evidence}
    assert failed.request_id == request_id
    assert failed.todo_verifier_data == nil
    refute text(failed.context.messages) =~ "obsolete blocked acceptance"
    refute_received {:atl47_model, _, :lead, _, _}
    refute_received {:atl47_verify, _, _, _, _}
  end

  for accepted? <- [true, false] do
    test "a held #{accepted?} verdict cannot adopt stale feedback or data while newly delegated work is unfinished",
         ctx do
      owner = start_owner(ctx, verify_options())
      require_work(ctx, owner)
      request_id = ask_owner(ctx, owner)
      assert_receive {:atl47_model, lead, :lead, _, _}, 5_000
      respond(lead, Responses.final_answer_response("proposal before delegation"))
      assert_receive {:atl47_verify, old_verifier, _, actor, tenant}, 5_000

      owner_command!(ctx, owner, :add_member, %{
        member: "unfinished-worker",
        template: :worker,
        activation: :lazy,
        initial_state: %{
          model: "offline",
          client: Atl47Native.Client,
          llm_opts: [observer: self(), label: :worker],
          tools: []
        }
      })

      owner_command!(ctx, owner, :assign_task, %{
        member: "unfinished-worker",
        task_id: "unfinished-evidence",
        payload: %{text: "finish fresh evidence"},
        requester: :self,
        notify: :self,
        mode: :background,
        timeout_ms: 30_000
      })

      assert_receive {:atl47_model, worker, :worker, _, _}, 5_000
      assert {:ok, before_verdict} = ai(owner)
      assert before_verdict.todo_verification_pending
      assert before_verdict.queued_messages == []

      verdict(
        old_verifier,
        Aikido.AiReact.TodoVerification.new!(
          %{
            accepted?: unquote(accepted?),
            feedback: "stale unfinished-worker feedback",
            data: %{stale_unfinished_worker: true}
          },
          []
        )
      )

      waiting = await_ai(owner, &(&1.status == :waiting))
      assert waiting.request_id == request_id
      assert waiting.todo_idle_reminder == nil
      assert waiting.todo_verifier_data == nil
      refute text(waiting.context.messages) =~ "stale unfinished-worker feedback"
      refute_received {:atl47_model, _, :lead, _, _}
      refute_received {:atl47_verify, _, _, _, _}

      respond(worker, Responses.final_answer_response("fresh completed worker evidence"))
      assert_receive {:atl47_model, resumed, :lead, messages, _}, 5_000
      assert text(messages) =~ "fresh completed worker evidence"
      refute text(messages) =~ "stale unfinished-worker feedback"
      assert {:ok, resumed_state} = ai(owner)
      assert resumed_state.request_id == request_id
      assert resumed_state.todo_verifier_data == nil
      assert resumed_state.run_scope.actor == actor
      assert resumed_state.run_scope.tenant == tenant
      respond(resumed, Responses.final_answer_response("proposal with completed worker evidence"))
      assert_receive {:atl47_verify, fresh_verifier, arguments, ^actor, ^tenant}, 5_000
      assert arguments.data == nil

      verdict(
        fresh_verifier,
        Aikido.AiReact.TodoVerification.new!(
          %{
            accepted?: true,
            data: %{fresh_completed_worker: true}
          },
          []
        )
      )

      completed = await_ai(owner, &(&1.status == :completed))
      assert completed.request_id == request_id
      assert completed.result == "proposal with completed worker evidence"
      assert completed.todo_verifier_data == %{fresh_completed_worker: true}
    end
  end

  test "a verifier with a native embedded return contract carries false feedback and private data before typed acceptance",
       ctx do
    owner = start_owner(ctx, %{todo_verifier: {Atl47Native.Verifier, :verify_typed}})
    require_work(ctx, owner)
    request_id = ask_owner(ctx, owner)
    assert_receive {:atl47_model, first, :lead, _, _}, 5_000
    respond(first, Responses.final_answer_response("first typed proposal"))
    assert_receive {:atl47_verify, verifier, arguments, actor, tenant}, 5_000
    assert arguments.data == nil
    assert actor == ctx.scope[:actor]
    assert tenant == ctx.scope[:tenant]
    private = %{phase: :review, marker: "typed-return-private-evidence"}

    verdict(
      verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{accepted?: false, feedback: "Review the native typed evidence", data: private},
        []
      )
    )

    assert_receive {:atl47_model, second, :lead, messages, _}, 5_000
    assert text(messages) =~ "Review the native typed evidence"
    refute text(messages) =~ "typed-return-private-evidence"
    assert {:ok, reviewing} = ai(owner)
    assert reviewing.request_id == request_id
    assert reviewing.todo_verifier_data == private
    assert reviewing.run_scope.actor == actor
    assert reviewing.run_scope.tenant == tenant
    respond(second, Responses.final_answer_response("reviewed typed proposal"))
    assert_receive {:atl47_verify, fresh_verifier, fresh_arguments, ^actor, ^tenant}, 5_000
    assert fresh_arguments.data == private

    verdict(
      fresh_verifier,
      Aikido.AiReact.TodoVerification.new!(
        %{accepted?: true, data: %{phase: :accepted}},
        []
      )
    )

    completed = await_ai(owner, &(&1.status == :completed))
    assert completed.request_id == request_id
    assert completed.result == "reviewed typed proposal"
    assert completed.todo_verifier_data == %{phase: :accepted}
    refute_received {:atl47_model, _, :lead, _, _}
  end
end
