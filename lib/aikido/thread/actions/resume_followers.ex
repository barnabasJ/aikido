defmodule Aikido.Thread.Actions.ResumeFollowers do
  @moduledoc "Resume only previously authorized unacknowledged ranges after source activation."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    thread = input.arguments.state
    {updated, directives} = Aikido.Thread.Followers.resume(thread, input.context.aikido, :thread)

    Aikido.Types.ActionResult.new(
      changes: Aikido.Thread.Journal.changes(thread, updated),
      directives: directives
    )
  end
end
