defmodule Aikido.Team.Actions.OperationCompleted do
  @moduledoc "Releases queued topology commands after lifecycle completion, then retires idle task-scoped workers."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    {_signal, state, context, _config} = Aikido.Team.ActionAdapter.unpack_team_action(input)

    {state, directives} = Aikido.Team.TopologyOperation.release_queued_operations(state, context)

    changes =
      if state.queued_operations == input.arguments.state.queued_operations,
        do: nil,
        else: %{queued_operations: state.queued_operations}

    Aikido.Types.ActionResult.new(changes: changes, directives: directives)
  end
end
