defmodule Aikido.Thread.Actions.Append do
  @moduledoc "Appends entries with input-derived timestamps and deterministic thread entry IDs."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    thread = input.arguments.state
    context = input.context[:aikido] || %{signal: %Aikido.Signal{type: "aikido.thread.append"}}

    with {:ok, updated} <- Aikido.Thread.Journal.append(thread, entry, context.signal) do
      {updated, directives} = Aikido.Thread.Followers.offer_all(updated, context, :thread)

      Aikido.Types.ActionResult.new(
        changes: Aikido.Thread.Journal.changes(thread, updated),
        directives: directives
      )
    end
  end
end
