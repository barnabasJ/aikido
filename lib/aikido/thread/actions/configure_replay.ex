defmodule Aikido.Thread.Actions.ConfigureReplay do
  @moduledoc "Adopt replay receipts through a native action while preserving original entry identity and order."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.{EntryReceipts, Journal}

  @impl true
  def run(input, _options, _context) do
    thread = input.arguments.state

    if input.arguments.path == input.context.aikido.slice_path do
      with :ok <- replayable_history(thread.entries),
           {:ok, receipts} <- EntryReceipts.retained(thread) do
        floor =
          case thread.entries do
            [] -> thread.first_sequence
            [first | _] -> first.seq
          end

        updated = %{
          thread
          | replay?: true,
            first_sequence: floor,
            next_sequence: Journal.next_sequence(thread),
            entry_receipts: receipts |> Map.values() |> Enum.sort_by(& &1.seq),
            metadata: DeepMerge.deep_merge(thread.metadata, input.arguments.metadata)
        }

        Aikido.Types.ActionResult.new(changes: Journal.changes(thread, updated))
      end
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end

  defp replayable_history(entries) do
    unique? = length(Enum.uniq_by(entries, & &1.id)) == length(entries)

    contiguous? =
      Enum.all?(Enum.chunk_every(entries, 2, 1, :discard), fn [first, second] ->
        second.seq == first.seq + 1
      end)

    if unique? && contiguous? do
      :ok
    else
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :state,
         message:
           "Replay requires unique entry IDs and contiguous ordered sequences. Existing history was left unchanged; configuration cannot regenerate or clear it."
       )}
    end
  end
end
