defmodule Aikido.Team.Actions.ResumeRoster do
  @moduledoc "Resume outstanding authorized roster ranges on source activation."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    journal = input.arguments.state.membership_journal

    {updated, directives} =
      if journal,
        do: Aikido.Thread.Followers.resume(journal, input.context.aikido, :roster),
        else: {journal, []}

    changes = if journal, do: Aikido.Thread.Journal.changes(journal, updated), else: %{}

    Aikido.Types.ActionResult.new(
      changes: if(changes == %{}, do: %{}, else: %{membership_journal: changes}),
      directives: directives
    )
  end
end
