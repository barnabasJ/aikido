defmodule Aikido.Ownership.Actions.ReleaseMonitors do
  @moduledoc "Releases parent and owned-child monitors before the owner stops."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    directives =
      Aikido.Ownership.Monitors.release(%{ref: input.arguments.state.parent_monitor}) ++
        Enum.flat_map(input.arguments.state.children, fn {_, child} ->
          Aikido.Ownership.Monitors.release(child)
        end)

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | children: %{}, parent_monitor: nil},
      directives: directives
    )
  end
end
