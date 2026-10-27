defmodule Aikido.Ownership.Actions.RecordChildMonitor do
  @moduledoc "Adopts a child's monitor only while the same process still owns its tag."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    %{tag: tag, pid: pid, ref: ref} = input.arguments

    case Map.get(state.children, tag) do
      %{pid: ^pid, ref: nil} = child ->
        Aikido.Types.ActionResult.new(
          state: %{state | children: Map.put(state.children, tag, %{child | ref: ref})}
        )

      %{pid: ^pid, ref: ^ref} ->
        Aikido.Types.ActionResult.new(state: state)

      _ ->
        Aikido.Types.ActionResult.new(
          state: state,
          directives: [%Aikido.Directives.Demonitor{ref: ref}]
        )
    end
  end
end
