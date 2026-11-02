defmodule AgentExamples.Telemetry.SignalSeries do
  @moduledoc "Bounded signal throughput and duration histograms, with no per-agent history."
  @buckets [
    10,
    25,
    50,
    100,
    250,
    500,
    1000,
    2500,
    5000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
    10_000_000,
    30_000_000,
    60_000_000
  ]

  def new do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    for bucket <- @buckets ++ [:overflow], do: :ets.insert(__MODULE__, {bucket, 0})
    %{sampled_at: System.monotonic_time(:millisecond), total: 0, histogram: %{}, points: []}
  end

  def record(nil), do: :ok

  def record(duration) do
    microseconds = System.convert_time_unit(duration, :native, :microsecond)
    bucket = Enum.find(@buckets, :overflow, &(microseconds <= &1))
    :ets.update_counter(__MODULE__, bucket, {2, 1})
    :ok
  end

  def sample(state, total) do
    now = System.monotonic_time(:millisecond)
    histogram = Map.new(:ets.tab2list(__MODULE__))

    delta =
      Map.new(histogram, fn {bucket, count} ->
        {bucket, count - Map.get(state.histogram, bucket, 0)}
      end)

    point = %{
      at: System.system_time(:millisecond),
      throughput: (total - state.total) * 1000 / max(now - state.sampled_at, 1),
      median_ms: quantile(delta, 0.5),
      p95_ms: quantile(delta, 0.95)
    }

    %{
      state
      | sampled_at: now,
        total: total,
        histogram: histogram,
        points: Enum.take(state.points ++ [point], -120)
    }
  end

  @doc "Returns the histogram upper bound in milliseconds; nil means no durations or overflow."
  def quantile(histogram, fraction) do
    count = Enum.sum(Map.values(histogram))

    if count > 0 do
      rank = ceil(count * fraction)

      Enum.reduce_while(@buckets, 0, fn bucket, seen ->
        seen = seen + Map.get(histogram, bucket, 0)
        if seen >= rank, do: {:halt, {:value, bucket / 1000}}, else: {:cont, seen}
      end)
      |> case do
        {:value, value} -> value
        _ -> nil
      end
    end
  end
end
