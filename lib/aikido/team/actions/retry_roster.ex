defmodule Aikido.Team.Actions.RetryRoster do
  @moduledoc "RetryRoster through the native authorized Team membership journal."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state
    context = input.context.aikido

    if input.arguments.path == context.slice_path && not is_nil(state.membership_journal) do
      {journal, directives} =
        Aikido.Thread.Followers.retry(state.membership_journal, input.arguments, context, :roster)

      result(state, journal, directives)
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end

  defp result(state, journal, directives) do
    changes = Aikido.Thread.Journal.changes(state.membership_journal, journal)

    Aikido.Types.ActionResult.new(
      changes: if(changes == %{}, do: %{}, else: %{membership_journal: changes}),
      directives: directives
    )
  end
end
