defmodule Aikido.Team.Actions.ConfigureRosterReplay do
  @moduledoc "Enable a retained team's roster journal through native embedded adoption."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state

    cond do
      input.arguments.path != input.context.aikido.slice_path ->
        Aikido.Types.ActionResult.new(changes: nil)

      is_nil(state.membership_journal) ->
        with {:ok, journal} <-
               Aikido.Team.Roster.initial_journal(
                 state,
                 input.arguments.metadata,
                 input.context.aikido
               ) do
          Aikido.Types.ActionResult.new(changes: %{membership_journal: journal})
        end

      true ->
        Aikido.Types.ActionResult.new(
          changes: %{
            membership_journal: %{
              replay?: true,
              metadata:
                DeepMerge.deep_merge(state.membership_journal.metadata, input.arguments.metadata)
            }
          }
        )
    end
  end
end
