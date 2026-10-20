defmodule Aikido.Slices.Thread.EntryNormalizer do
  @moduledoc """
  Contextual entry preparation for thread appends.

  Supplies sequence, timestamp and ID before native Ash validation for
  `%Aikido.Slices.Thread.Entry{}` structs and plain maps.
  """

  alias Aikido.Slices.Thread.Entry

  @type entry_input :: Entry.t() | map()
  @type opts :: [id_generator: (-> String.t()) | (non_neg_integer() -> String.t())]

  @doc """
  Normalize a single entry input into `%Aikido.Slices.Thread.Entry{}`.
  """
  @spec normalize(entry_input(), non_neg_integer(), integer(), opts()) :: Entry.t()
  def normalize(entry, seq, now, opts \\ [])

  def normalize(%Entry{} = entry, seq, now, opts),
    do: normalize(Map.from_struct(entry), seq, now, opts)

  def normalize(attrs, seq, now, opts) when is_map(attrs) do
    id_generator = Keyword.get(opts, :id_generator, &generate_entry_id/0)

    Entry.new!(
      id: fetch_entry_attr(attrs, :id, fn -> generate_id(id_generator, seq) end),
      seq: seq,
      at: fetch_entry_attr(attrs, :at, fn -> now end),
      kind: fetch_entry_attr(attrs, :kind, fn -> :note end),
      payload: fetch_entry_attr(attrs, :payload, fn -> %{} end),
      refs: fetch_entry_attr(attrs, :refs, fn -> %{} end)
    )
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

  defp fetch_entry_attr(attrs, key, default_fun) when is_function(default_fun, 0) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> default_fun.()
      value -> value
    end
  end

  defp generate_id(generator, seq) when is_function(generator, 1), do: generator.(seq)
  defp generate_id(generator, _seq), do: generator.()

  defp generate_entry_id do
    "entry_" <> Ash.UUIDv7.generate()
  end
end
