defmodule Aikido.AiReact.Actions.TodoChanged do
  @moduledoc "Reevaluates a waiting run against blocking todos and plans its completion hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion, Hooks}

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.status == :waiting do
      state =
        state
        |> Completion.resolve_todo_status(input.context.aikido.agent.state)
        |> Completion.clear_tools_and_handoff()

      Hooks.queue_event_hooks(
        Aikido.Types.ActionResult.new(state: state),
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
