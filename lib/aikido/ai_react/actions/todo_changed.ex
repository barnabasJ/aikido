defmodule Aikido.AiReact.Actions.TodoChanged do
  @moduledoc "Reevaluates a waiting run against blocking todos and plans its completion hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{RunState, TodoRequirements, HookQueue}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_todo_change(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp process_todo_change(input) do
    state = input.arguments.state

    if state.status == :waiting do
      {state, directives} =
        state
        |> TodoRequirements.plan_run_outcome(input.context.aikido.agent.state)

      state = RunState.clear_tools_and_handoff(state)

      HookQueue.queue_event_hooks(
        {:ok, state, directives},
        :after_model,
        %{
          todo_completion: true
        }
      )
    else
      {:ok, state, []}
    end
  end
end
