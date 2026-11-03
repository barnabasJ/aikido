defmodule Aikido.Thread.EntryReceipts do
  @moduledoc "Native Ash entry dumping and immutable-content receipts for idempotent append."
  @entry_constraints (case Ash.Type.init(Aikido.Thread.Types.Entry, []) do
                        {:ok, constraints} -> constraints
                      end)

  def from_entry(entry) do
    with {:ok, dumped} <-
           Ash.Type.dump_to_embedded(Aikido.Thread.Types.Entry, entry, @entry_constraints),
         {:ok, binary} <- Ash.Type.dump_to_embedded(:term, dumped) do
      {:ok,
       Aikido.Thread.Types.EntryReceipt.new!(
         id: entry.id,
         seq: entry.seq,
         at: entry.at,
         refs: entry.refs,
         digest: binary |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
       )}
    end
  end

  def retained(thread) do
    Enum.reduce_while(
      thread.entries,
      {:ok, Map.new(thread.entry_receipts, &{&1.id, &1})},
      fn entry, {:ok, known} ->
        if Map.has_key?(known, entry.id) do
          {:cont, {:ok, known}}
        else
          case from_entry(entry) do
            {:ok, receipt} -> {:cont, {:ok, Map.put(known, receipt.id, receipt)}}
            error -> {:halt, error}
          end
        end
      end
    )
  end
end
