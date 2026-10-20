defmodule Aikido.Slices.AiWorker.Observe do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    context = input.context.aikido

    if (state.pending || Map.get(state, :queue, []) != []) &&
         input.context.aikido.signal.type != "ai.react.stream" do
      observe =
        struct!(Jido.Signal,
          id: nil,
          type: "harness.ai.observe",
          data: %{task_id: state.pending && state.pending.task_id},
          source: "/aikido"
        )

      Aikido.Types.ActionResult.new(
        state: state,
        directives: [Aikido.Directives.emit_to_pid(observe, context.agent_pid)]
      )
    else
      Aikido.Types.ActionResult.new(state: state, directives: [])
    end
  end
end
