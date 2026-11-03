defmodule Aikido.Thread.Journal do
  @moduledoc "Pure immutable entry adoption shared by Thread and the Team membership journal."
  alias Aikido.Thread.Types.Entry

  @entry_constraints (case Ash.Type.init(Entry, []) do
                        {:ok, constraints} -> constraints
                      end)

  @doc "Append new immutable IDs, ignore identical retries and reject conflicting reuse atomically."
  def append(%{replay?: false} = thread, entries, signal) do
    now = Aikido.Signal.timestamp(signal)

    entries =
      entries
      |> List.wrap()
      |> Enum.with_index(length(thread.entries))
      |> Enum.map(fn {attributes, sequence} ->
        attributes
        |> Map.put(:seq, sequence)
        |> Map.put_new(:id, value(attributes, :id, "#{thread.id}:#{thread.rev}:#{sequence}"))
        |> Map.put_new(:at, value(attributes, :at, now))
      end)

    with {:ok, entries} <- Ash.Type.cast_input({:array, Entry}, entries) do
      count = length(entries)

      {:ok,
       %{
         thread
         | entries: thread.entries ++ entries,
           rev: thread.rev + count,
           updated_at: now,
           stats: %{thread.stats | entry_count: thread.stats.entry_count + count}
       }}
    end
  end

  def append(thread, entries, signal) do
    now = Aikido.Signal.timestamp(signal)

    with {:ok, appended, receipts} <- cast_new_entries(thread, List.wrap(entries), signal, now) do
      thread = %{thread | entry_receipts: receipts}

      if appended == [] do
        {:ok, thread}
      else
        {:ok,
         Map.merge(thread, %{
           entries: thread.entries ++ appended,
           next_sequence: next_sequence(thread) + length(appended),
           rev: thread.rev + length(appended),
           updated_at: now,
           stats: %{thread.stats | entry_count: thread.stats.entry_count + length(appended)}
         })}
      end
    end
  end

  @doc "Reject replay operations on ordinary Thread mounts that did not opt in."
  def require_replay(%{replay?: true}), do: :ok

  def require_replay(_thread) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :path,
       message:
         "Replay is disabled for this Thread mount. Start it with replay?: true before using Follow or Prune."
     )}
  end

  @doc "The next sequence, including retained records created before sequence bookkeeping."
  def next_sequence(thread) do
    case List.last(thread.entries) do
      nil -> thread.next_sequence
      last -> max(thread.next_sequence, last.seq + 1)
    end
  end

  @doc "Sparse native embedded-resource attributes for an updated journal."
  def changes(previous, updated) do
    updated
    |> Map.take(Enum.map(Ash.Resource.Info.attributes(Aikido.Thread.Slice), & &1.name))
    |> Map.reject(fn {key, value} -> Map.get(previous, key) == value end)
  end

  defp cast_new_entries(thread, entries, signal, now) do
    with {:ok, known} <- Aikido.Thread.EntryReceipts.retained(thread) do
      Enum.reduce_while(entries, {:ok, [], known}, fn attributes, {:ok, appended, known} ->
        sequence = next_sequence(thread) + length(appended)
        id = value(attributes, :id, "#{thread.id}:#{thread.rev}:#{sequence}")
        existing = known[id]

        attributes =
          attributes
          |> Map.put(:id, id)
          |> Map.put(:seq, if(existing, do: existing.seq, else: sequence))
          |> Map.put(:at, value(attributes, :at, if(existing, do: existing.at, else: now)))
          |> Map.put(
            :refs,
            value(attributes, :refs, if(existing, do: existing.refs, else: signal_refs(signal)))
          )

        with {:ok, entry} <- Ash.Type.cast_input(Entry, attributes, @entry_constraints),
             {:ok, receipt} <- Aikido.Thread.EntryReceipts.from_entry(entry) do
          cond do
            is_nil(existing) ->
              {:cont, {:ok, appended ++ [entry], Map.put(known, id, receipt)}}

            receipt == existing ->
              {:cont, {:ok, appended, known}}

            true ->
              {:halt,
               {:error,
                Ash.Error.Action.InvalidArgument.exception(
                  field: :entry,
                  message:
                    "Entry #{inspect(id)} already exists with different immutable content. Use a new entry ID for different data."
                )}}
          end
        else
          {:error, _} = error ->
            {:halt, error}

          :error ->
            {:halt,
             {:error,
              Ash.Error.Action.InvalidArgument.exception(
                field: :entry,
                message: "Entry does not satisfy the native Thread entry type."
              )}}
        end
      end)
      |> case do
        {:ok, appended, known} -> {:ok, appended, known |> Map.values() |> Enum.sort_by(& &1.seq)}
        error -> error
      end
    end
  end

  defp value(attributes, key, default),
    do: Map.get(attributes, key, Map.get(attributes, Atom.to_string(key), default))

  defp signal_refs(%{id: nil}), do: %{}

  defp signal_refs(signal),
    do: %{
      signal_id: signal.id,
      signal_type: signal.type,
      signal_time: Aikido.Signal.timestamp(signal)
    }
end
