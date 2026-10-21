defmodule Aikido.Thread.EntryNormalizer do
  @moduledoc """
  Contextual entry preparation for thread appends.

  Supplies sequence, timestamp and ID before native Ash validation for
  `%Aikido.Thread.Entry{}` structs and plain maps.
  """

  alias Aikido.Thread.Entry

  @type entry_input :: Entry.t() | map()
  @type opts :: [id_generator: (-> String.t()) | (non_neg_integer() -> String.t())]

  @doc """
  Normalize a single entry input into `%Aikido.Thread.Entry{}`.
  """
  @spec normalize(entry_input(), non_neg_integer(), integer(), opts()) :: Entry.t()
  def normalize(entry, seq, now, opts \\ [])

  def normalize(%Entry{} = entry, seq, now, opts),
    do: normalize(Map.from_struct(entry), seq, now, opts)

  def normalize(attrs, seq, now, opts) when is_map(attrs) do
    attrs = Map.reject(attrs, fn {_, value} -> is_nil(value) end)
    id_generator = Keyword.get(opts, :id_generator, &generate_entry_id/0)

    attrs
    |> Map.put(:seq, seq)
    |> Map.put_new_lazy(:id, fn -> Map.get(attrs, "id") || generate_id(id_generator, seq) end)
    |> Map.put_new(:at, Map.get(attrs, "at", now))
    |> Entry.new!()
  end

  @doc """
  Normalize many entries, assigning monotonic sequence numbers from `base_seq`.
  """
  @spec normalize_many([entry_input()], non_neg_integer(), integer(), opts()) :: [Entry.t()]
  def normalize_many(entries, base_seq, now, opts \\ []) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      normalize(entry, base_seq + idx, now, opts)
    end)
  end

  defp generate_id(generator, seq) when is_function(generator, 1), do: generator.(seq)
  defp generate_id(generator, _seq), do: generator.()

  defp generate_entry_id do
    "entry_" <> Ash.UUIDv7.generate()
  end
end
