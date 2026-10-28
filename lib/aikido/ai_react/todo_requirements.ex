defmodule Aikido.AiReact.TodoRequirements do
  @moduledoc """
  Decides whether blocking todos permit a ReAct run to finish.

  This optional policy maps the current todo state to completed, waiting or
  failed run status. It neither executes todos nor clears run resources.
  """

  @doc "Plan a verifier or bounded continuation when a proposed answer leaves blocking work."
  def plan_run_outcome(state, agent_state, options \\ []) do
    state = resolve_run_status(state, agent_state)

    cond do
      state.options.completion == :todos && state.status in [:waiting, :completed] &&
          Aikido.Team.TaskCompletion.awaiting_background_results?(agent_state) ->
        {%{state | status: :waiting, todo_idle_reminder: nil}, []}

      state.options.todo_continuation == :nudge_once && state.status == :waiting &&
          work_in_flight?(state, agent_state) ->
        {state, []}

      state.options.completion == :todos && state.status in [:waiting, :completed] &&
          not is_nil(state.options.todo_verifier) ->
        verifier = %Aikido.AiReact.Directives.VerifyTodos{
          action: state.options.todo_verifier,
          run_scope: state.run_scope,
          revision: Map.fetch!(agent_state, state.options.todo_path).revision,
          answer: state.result,
          data: %{value: Map.get(state, :todo_verifier_data)},
          final_answer?: Keyword.get(options, :final_answer?, false),
          todos: blocking_todos(state, agent_state),
          metadata: state.run_metadata,
          request_id: state.request_id,
          iteration: state.iteration,
          timeout: state.options.model_timeout_ms,
          deadline_at: state.deadline_at,
          tool_context: state.tool_context
        }

        {%{state | status: :running, todo_verification_pending: true}, [verifier]}

      true ->
        continue_after_verification(
          state,
          agent_state,
          Keyword.get(options, :final_answer?, false)
        )
    end
  end

  @doc "Apply continuation policy to a correlated verifier rejection or an unverified answer."
  def continue_after_verification(
        %{status: :waiting, options: %{completion: :todos}} = state,
        agent_state,
        final_answer?
      ) do
    if Aikido.Team.TaskCompletion.awaiting_background_results?(agent_state),
      do: {%{state | todo_idle_reminder: nil}, []},
      else: continue_todo_policy(state, agent_state, final_answer?)
  end

  def continue_after_verification(state, agent_state, final_answer?),
    do: continue_todo_policy(state, agent_state, final_answer?)

  defp continue_todo_policy(
         %{status: :waiting, options: %{todo_continuation: :nudge_once}} = state,
         agent_state,
         true
       ) do
    if work_in_flight?(state, agent_state),
      do: {state, []},
      else: nudge_or_fail_idle_answer(state, agent_state)
  end

  defp continue_todo_policy(state, agent_state, _final_answer?),
    do: continue_or_wait(state, agent_state)

  defp nudge_or_fail_idle_answer(state, agent_state) do
    todos = Map.fetch!(agent_state, state.options.todo_path)
    remaining = Enum.reject(blocking_todos(state, agent_state), &(&1.status == :completed))

    settle_idle_obligations(state, remaining, todos.revision)
  end

  defp settle_idle_obligations(state, [], _revision), do: {state, []}

  defp settle_idle_obligations(state, remaining, revision) do
    case Map.get(state, :todo_idle_reminder) do
      %{revision: ^revision, iteration: iteration} when iteration < state.iteration ->
        error =
          Aikido.AiReact.Errors.CompletedUnclosed.exception(
            todos: Enum.map(remaining, &Map.take(&1, [:id, :text]))
          )

        {%{state | status: :failed, result: nil, error: error}, []}

      %{revision: ^revision, iteration: iteration} when iteration >= state.iteration ->
        {state, []}

      _ ->
        request_idle_todo_reminder(state, remaining, revision)
    end
  end

  defp request_idle_todo_reminder(state, remaining, revision) do
    if continuation_budget_exhausted?(state) do
      continuation_limit(state)
    else
      state =
        Map.put(state, :todo_idle_reminder, %{revision: revision, iteration: state.iteration})

      request_todo_continuation(state, remaining)
    end
  end

  defp work_in_flight?(state, agent_state) do
    state.pending_tool_calls != [] || map_size(state.hooks_pending) > 0 ||
      not is_nil(state.handoff_pending) || not is_nil(state.tools_resume) ||
      Aikido.Team.TaskCompletion.awaiting_background_results?(agent_state)
  end

  @doc "Request another model turn for open work when enabled, within both continuation and iteration limits."
  def continue_or_wait(
        %{status: :waiting, options: %{todo_continuation: :continue}} = state,
        agent_state
      ) do
    if continuation_budget_exhausted?(state) do
      continuation_limit(state)
    else
      remaining = blocking_todos(state, agent_state) |> Enum.reject(&(&1.status == :completed))
      request_todo_continuation(state, remaining)
    end
  end

  def continue_or_wait(state, _agent_state), do: {state, []}

  defp continuation_budget_exhausted?(state),
    do:
      state.todo_continuations >= state.options.max_todo_continuations ||
        state.iteration >= state.max_iterations

  defp continuation_limit(state),
    do:
      {%{state | status: :failed, error: {:todo_continuation_limit, state.todo_continuations}},
       []}

  defp request_todo_continuation(state, remaining) do
    text =
      "Continue the remaining work and use tools to provide completion evidence:\n" <>
        Enum.map_join(remaining, "\n", &"- #{&1.id}: #{&1.text}")

    state =
      state
      |> Aikido.AiReact.Conversation.append_message(ReqLLM.Context.user(text))
      |> Map.merge(%{
        status: :running,
        result: nil,
        todo_continuations: state.todo_continuations + 1
      })

    {:ok, state, directives} = Aikido.AiReact.RunState.request_model_turn(state)
    {state, directives}
  end

  defp blocking_todos(state, agent_state) do
    case Map.get(agent_state, state.options.todo_path) do
      %{items: items} -> Enum.filter(items, & &1.blocking?)
      _ -> []
    end
  end

  @doc "Resolve completed, waiting or failed status from the configured blocking todos."
  def resolve_run_status(state, agent_state) do
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}

    if options.completion == :todos do
      case Map.get(agent_state, options.todo_path) do
        %{items: items} -> resolve_blocking_todos(state, Enum.filter(items, & &1.blocking?))
        _ -> Map.merge(state, %{status: :failed, error: :todo_slice_not_mounted})
      end
    else
      state
    end
  end

  defp resolve_blocking_todos(state, items) do
    cond do
      blocked = Enum.find(items, &(&1.status == :blocked)) ->
        Map.merge(state, %{
          status: :failed,
          error: {:todo_blocked, blocked.id, blocked.reason}
        })

      Enum.any?(items, &(&1.status != :completed)) ->
        Map.put(state, :status, :waiting)

      true ->
        Map.put(state, :status, :completed)
    end
  end
end
