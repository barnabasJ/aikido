defmodule Aikido.AiReact.Actions.TodoChanged do
  @moduledoc "Reevaluates a waiting run against blocking todos and plans its completion hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{RunState, TodoRequirements, HookQueue}

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.status == :waiting do
      {state, directives} =
        state
        |> TodoRequirements.plan_run_outcome(input.context.aikido.agent.state)

      state = RunState.clear_tools_and_handoff(state)

      HookQueue.queue_event_hooks(
        Aikido.Types.ActionResult.new(state: state, directives: directives),
        :after_model,
        %{
          todo_completion: true
        }
      )
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
