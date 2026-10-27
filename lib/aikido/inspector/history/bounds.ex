defmodule Aikido.Inspector.History.Bounds do
  @moduledoc "Keeps projected snapshots within their byte budget without flattening the tree."
  @marker "[size limit]"

  def limit(value, budget \\ 32_768) do
    if byte_size(Jason.encode!(value)) <= budget, do: value, else: trim(value, budget)
  end

  defp trim(value, budget) when is_map(value) do
    overhead = value |> Map.new(fn {key, _} -> {key, nil} end) |> Jason.encode!() |> byte_size()

    if budget < overhead + map_size(value) * 16 do
      @marker
    else
      share = div(budget - overhead, max(map_size(value), 1))
      Map.new(value, fn {key, child} -> {key, limit(child, share)} end)
    end
  end

  defp trim(value, budget) when is_list(value) do
    if budget < 2 + length(value) * 17 do
      @marker
    else
      share = div(budget - 2 - length(value), max(length(value), 1))
      Enum.map(value, &limit(&1, share))
    end
  end

  defp trim(value, budget) when is_binary(value) and budget >= 32,
    do: String.slice(value, 0, div(budget - 24, 6)) <> "… [truncated]"

  defp trim(_value, _budget), do: @marker
end
