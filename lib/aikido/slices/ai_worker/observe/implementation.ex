defmodule Aikido.Slices.AiWorker.Observe.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    context = input.context.aikido

    if state.pending do
      observe = Jido.Signal.new!("harness.ai.observe", %{task_id: state.pending.task_id})

      Aikido.ActionResult.new(
        state: state,
        directives: [Aikido.Directives.emit_to_pid(observe, context.agent_pid)]
      )
    else
      Aikido.ActionResult.new(state: state, directives: [])
    end
  end
end
