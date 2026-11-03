defmodule Aikido.Thread.Actions.Unfollow do
  @moduledoc "Unfollow one explicitly authorized Thread consumer through the native signal action."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    thread = input.arguments.state
    context = input.context.aikido

    if input.arguments.path == context.slice_path do
      updated = Aikido.Thread.Followers.unfollow(thread, input.arguments.consumer)
      directives = []

      Aikido.Types.ActionResult.new(
        changes: Aikido.Thread.Journal.changes(thread, updated),
        directives: directives
      )
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end
end
