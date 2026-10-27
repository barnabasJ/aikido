defmodule Aikido.Thread.Actions.Append do
  @moduledoc "Appends entries with input-derived timestamps and deterministic thread entry IDs."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    thread = input.arguments.state
    now = Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))

    with {:ok, entries} <- stamp_and_cast_entries(List.wrap(entry), thread, now) do
      thread
      |> append_entries(entries, now)
      |> then(&Aikido.Types.ActionResult.new(state: &1))
    end
  end

  defp append_entries(thread, entries, now) do
    count = length(entries)

    %{
      thread
      | entries: thread.entries ++ entries,
        rev: thread.rev + count,
        updated_at: now,
        stats: %{thread.stats | entry_count: thread.stats.entry_count + count}
    }
  end

  defp stamp_and_cast_entries(entries, thread, now) do
    entries
    |> Enum.with_index(length(thread.entries))
    |> Enum.map(fn {attrs, sequence} -> stamp_entry(attrs, sequence, thread, now) end)
    |> then(&Ash.Type.cast_input({:array, Aikido.Thread.Types.Entry}, &1))
  end

  defp stamp_entry(attrs, sequence, thread, now) do
    attrs
    |> Map.put(:seq, sequence)
    |> Map.put_new(:id, Map.get(attrs, "id", "#{thread.id}:#{thread.rev}:#{sequence}"))
    |> Map.put_new(:at, Map.get(attrs, "at", now))
  end
end
