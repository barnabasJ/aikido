defmodule Aikido.AiReact.Actions.TodosVerified do
  @moduledoc "Adopts a matching verification verdict and completes, waits or continues with bounded work."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.status == :running && state.todo_verification_pending &&
         state.request_id == input.arguments.request_id &&
         state.iteration == input.arguments.iteration do
      state = %{state | todo_verification_pending: false}

      {state, directives} = resolve_current_verdict(state, input)

      state = Aikido.AiReact.RunState.clear_tools_and_handoff(state)

      Aikido.Types.ActionResult.new(state: state, directives: directives)
      |> Aikido.AiReact.HookQueue.queue_event_hooks(:after_model, %{
        verification: input.arguments.result
      })
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp resolve_current_verdict(state, input) do
    agent_state = input.context.aikido.agent.state
    todos = Map.fetch!(agent_state, state.options.todo_path)

    cond do
      todos.revision != input.arguments.revision ->
        Aikido.AiReact.TodoRequirements.plan_run_outcome(
          %{state | status: :completed},
          agent_state
        )

      input.arguments.result ->
        {%{state | status: :completed}, []}

      true ->
        Aikido.AiReact.TodoRequirements.continue_or_wait(%{state | status: :waiting}, agent_state)
    end
  end
end
