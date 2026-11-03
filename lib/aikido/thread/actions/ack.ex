defmodule Aikido.Thread.Actions.Ack do
  @moduledoc "Ack one explicitly authorized Thread consumer through the native signal action."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    thread = input.arguments.state
    context = input.context.aikido

    if input.arguments.path == context.slice_path do
      {updated, directives} =
        Aikido.Thread.Followers.acknowledge(thread, input.arguments, context, :thread)

      Aikido.Types.ActionResult.new(
        changes: Aikido.Thread.Journal.changes(thread, updated),
        directives: directives
      )
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end
end
