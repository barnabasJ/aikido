defmodule Aikido.Thread.Actions.Prune do
  @moduledoc "Advance the replay retention floor and explicitly pause consumers whose cursors were pruned."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    thread = input.arguments.state
    context = input.context.aikido

    with :ok <- Aikido.Thread.Journal.require_replay(thread) do
      if input.arguments.path == context.slice_path do
        next = Aikido.Thread.Journal.next_sequence(thread)
        floor = max(thread.first_sequence, min(next, input.arguments.through_sequence + 1))
        entries = Enum.filter(thread.entries, &(&1.seq >= floor))

        with {:ok, receipts} <- Aikido.Thread.EntryReceipts.retained(thread) do
          updated =
            Map.merge(thread, %{
              entries: entries,
              first_sequence: floor,
              next_sequence: next,
              entry_receipts: receipts |> Map.values() |> Enum.sort_by(& &1.seq),
              rev: thread.rev + 1,
              stats: %{thread.stats | entry_count: length(entries)}
            })

          {updated, directives} = Aikido.Thread.Followers.offer_all(updated, context, :thread)

          Aikido.Types.ActionResult.new(
            changes: Aikido.Thread.Journal.changes(thread, updated),
            directives: directives
          )
        end
      else
        Aikido.Types.ActionResult.new(changes: nil)
      end
    end
  end
end
