defmodule Aikido.Ownership.Actions.RecordParentMonitor do
  @moduledoc "Records the current parent's monitor and releases stale acknowledgements."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    %{pid: pid, ref: ref} = input.arguments

    case {state.parent, state.parent_monitor} do
      {%{pid: ^pid}, nil} ->
        Aikido.Types.ActionResult.new(changes: %{parent_monitor: ref})

      {%{pid: ^pid}, ^ref} ->
        Aikido.Types.ActionResult.new(changes: nil)

      _ ->
        Aikido.Types.ActionResult.new(
          changes: nil,
          directives: [%Aikido.Directives.Demonitor{ref: ref}]
        )
    end
  end
end
