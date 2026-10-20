defmodule Aikido.Slices.Thread.Actions.Append do
  @moduledoc "Appends entries with input-derived timestamps and deterministic thread entry IDs."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Thread.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    thread = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Thread.append(thread, entry, entry_options(input, thread)),
      directives: []
    )
  end

  defp entry_options(input, thread) do
    Keyword.put(ActionOptions.from_input(input), :id_generator, fn seq ->
      "#{thread.id}:#{thread.rev}:#{seq}"
    end)
  end
end
