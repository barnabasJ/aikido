defmodule Aikido.AiReact.Actions.TodosVerified do
  @moduledoc "Adopts a matching verification verdict and completes, waits or continues with bounded work."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_todo_verdict(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp process_todo_verdict(input) do
    state = input.arguments.state

    if state.status == :running && state.todo_verification_pending &&
         state.request_id == input.arguments.request_id &&
         state.iteration == input.arguments.iteration do
      state = %{state | todo_verification_pending: false}

      {state, directives} = resolve_current_verdict(state, input)

      state = Aikido.AiReact.RunState.clear_tools_and_handoff(state)

      {:ok, state, directives}
      |> Aikido.AiReact.HookQueue.queue_event_hooks(:after_model, verification_payload(input))
    else
      {:ok, state, []}
    end
  end

  defp resolve_current_verdict(state, input) do
    agent_state = input.context.aikido.agent.state
    todos = Map.fetch!(agent_state, state.options.todo_path)
    current_outcome = Aikido.AiReact.TodoRequirements.resolve_run_status(state, agent_state)

    cond do
      current_outcome.status == :failed ->
        {current_outcome, []}

      awaiting_required_team_work?(state, agent_state) ->
        {%{state | status: :waiting, todo_idle_reminder: nil}, []}

      Map.get(state, :queued_messages, []) != [] ->
        resume_queued_evidence(state, agent_state)

      todos.revision != input.arguments.revision ->
        Aikido.AiReact.TodoRequirements.plan_run_outcome(
          %{state | status: :completed},
          agent_state,
          final_answer?: input.arguments[:final_answer?] || false
        )

      true ->
        state = adopt_verifier_data(state, input.arguments.result)

        if verification_accepted?(input.arguments.result) do
          accept_verified_answer(state, agent_state)
        else
          state = append_verification_feedback(state, input.arguments.result)

          Aikido.AiReact.TodoRequirements.continue_after_verification(
            %{state | status: :waiting},
            agent_state,
            input.arguments[:final_answer?] || false
          )
        end
    end
  end

  defp verification_payload(input) do
    state = input.arguments.state
    agent_state = input.context.aikido.agent.state
    todos = Map.fetch!(agent_state, state.options.todo_path)
    current_outcome = Aikido.AiReact.TodoRequirements.resolve_run_status(state, agent_state)

    if current_outcome.status != :failed && !awaiting_required_team_work?(state, agent_state) &&
         todos.revision == input.arguments.revision && Map.get(state, :queued_messages, []) == [],
       do: %{verification: verification_accepted?(input.arguments.result)},
       else: %{}
  end

  defp awaiting_required_team_work?(state, agent_state),
    do:
      state.options.completion == :todos &&
        Aikido.Team.TaskCompletion.awaiting_background_results?(agent_state)

  defp resume_queued_evidence(state, agent_state) do
    cond do
      Aikido.Team.TaskCompletion.awaiting_background_results?(agent_state) ->
        {%{state | status: :waiting, todo_idle_reminder: nil}, []}

      state.iteration >= state.max_iterations ->
        {%{state | status: :failed, result: nil, error: :max_iterations}, []}

      true ->
        {:ok, state, directives} = Aikido.AiReact.RunState.resume_queued_messages(state)
        {state, directives}
    end
  end

  defp accept_verified_answer(state, agent_state) do
    state = %{state | status: :completed}

    state =
      if state.options.completion == :todos,
        do: Aikido.Team.TaskCompletion.await_background_results(state, agent_state),
        else: state

    state = if state.status == :waiting, do: Map.put(state, :todo_idle_reminder, nil), else: state
    {state, []}
  end

  defp verification_accepted?(%Ash.Union{value: value}), do: verification_accepted?(value)

  defp verification_accepted?(%Aikido.AiReact.TodoVerification{accepted?: accepted?}),
    do: accepted?

  defp verification_accepted?(accepted?) when is_boolean(accepted?), do: accepted?

  defp adopt_verifier_data(state, %Ash.Union{value: value}), do: adopt_verifier_data(state, value)

  defp adopt_verifier_data(state, %Aikido.AiReact.TodoVerification{data: data}),
    do: Map.put(state, :todo_verifier_data, data)

  defp adopt_verifier_data(state, verdict) when is_boolean(verdict), do: state

  defp append_verification_feedback(state, %Ash.Union{value: value}),
    do: append_verification_feedback(state, value)

  defp append_verification_feedback(state, %Aikido.AiReact.TodoVerification{feedback: feedback})
       when is_binary(feedback) and byte_size(feedback) > 0,
       do: Aikido.AiReact.Conversation.append_message(state, ReqLLM.Context.user(feedback))

  defp append_verification_feedback(state, _verdict), do: state
end
