defmodule Aikido.Thread.Actions.Append do
  @moduledoc "Appends entries with input-derived timestamps and deterministic thread entry IDs."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    thread = input.arguments.state
    now = Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))

    with {:ok, entries} <- prepare_entries(List.wrap(entry), thread, now) do
      count = length(entries)

      Aikido.Types.ActionResult.new(
        state: %{
          thread
          | entries: thread.entries ++ entries,
            rev: thread.rev + count,
            updated_at: now,
            stats: %{thread.stats | entry_count: thread.stats.entry_count + count}
        }
      )
    end
  end

  defp prepare_entries(entries, thread, now) do
    entries =
      entries
      |> Enum.with_index(length(thread.entries))
      |> Enum.map(fn {attrs, seq} ->
        attrs
        |> Map.put(:seq, seq)
        |> Map.put_new(:id, Map.get(attrs, "id", "#{thread.id}:#{thread.rev}:#{seq}"))
        |> Map.put_new(:at, Map.get(attrs, "at", now))
      end)

    Ash.Type.cast_input({:array, Aikido.Thread.Types.Entry}, entries)
  end
end
