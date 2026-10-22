defmodule Aikido.AiReact.TodoRequirements do
  @moduledoc """
  Decides whether blocking todos permit a ReAct run to finish.

  This optional policy maps the current todo state to completed, waiting or
  failed run status. It neither executes todos nor clears run resources.
  """

  @doc "Plan a verifier or bounded continuation when a proposed answer leaves blocking work."
  def plan_run_outcome(state, agent_state) do
    state = resolve_run_status(state, agent_state)

    if state.options.completion == :todos && state.status in [:waiting, :completed] &&
         not is_nil(state.options.todo_verifier) do
      verifier = %Aikido.AiReact.Directives.VerifyTodos{
        action: state.options.todo_verifier,
        run_scope: state.run_scope,
        revision: Map.fetch!(agent_state, state.options.todo_path).revision,
        answer: state.result,
        todos: blocking_todos(state, agent_state),
        metadata: state.run_metadata,
        request_id: state.request_id,
        iteration: state.iteration,
        timeout: state.options.model_timeout_ms,
        tool_context: state.tool_context
      }

      {%{state | status: :running, todo_verification_pending: true}, [verifier]}
    else
      continue_or_wait(state, agent_state)
    end
  end

  @doc "Request another model turn for open work when enabled, within both continuation and iteration limits."
  def continue_or_wait(
        %{status: :waiting, options: %{todo_continuation: :continue}} = state,
        agent_state
      ) do
    if state.todo_continuations >= state.options.max_todo_continuations ||
         state.iteration >= state.max_iterations do
      {%{state | status: :failed, error: {:todo_continuation_limit, state.todo_continuations}},
       []}
    else
      remaining = blocking_todos(state, agent_state) |> Enum.reject(&(&1.status == :completed))

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

      {:ok, result} = Aikido.AiReact.RunState.request_model_turn(state)
      {result.state, result.directives}
    end
  end

  def continue_or_wait(state, _agent_state), do: {state, []}

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
