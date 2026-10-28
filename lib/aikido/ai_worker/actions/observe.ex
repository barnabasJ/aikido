defmodule Aikido.AiWorker.Actions.Observe do
  @moduledoc """
  Pure reducer that defers worker settlement until AI state has been committed.

  Preserves worker `state` and returns an `Emit` directive to the owning agent
  when work is pending or queued. Streaming signals do not trigger observations.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    context = input.context.aikido

    if (state.pending || Map.get(state, :queue, []) != []) &&
         input.context.aikido.signal.type != "ai.react.stream" do
      observe =
        %Aikido.Signal{
          id: nil,
          type: "harness.ai.observe",
          data: %{task_id: state.pending && state.pending.task_id},
          source: "/aikido"
        }

      Aikido.Types.ActionResult.new(
        changes: %{},
        directives: [Aikido.Directives.emit_to_pid(observe, context.agent_pid)]
      )
    else
      Aikido.Types.ActionResult.new(changes: %{})
    end
  end
end
