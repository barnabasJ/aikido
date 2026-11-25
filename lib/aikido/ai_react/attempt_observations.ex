defmodule Aikido.AiReact.AttemptObservations do
  @moduledoc "Transient I/O-side aggregation; wire publication is bounded by time, not chunk count."

  @interval_ms 100

  def new, do: %{latest: %{}, published: %{}, next_at: nil}

  def record(state, facts, now) do
    latest = Map.merge(state.latest, facts)

    milestone? =
      Enum.any?([:opened, :first_chunk_at, :first_progress_at], fn key ->
        Map.has_key?(latest, key) && not Map.has_key?(state.published, key)
      end)

    state = %{state | latest: latest}

    if latest != state.published &&
         (milestone? || is_nil(state.next_at) || now >= state.next_at) do
      {%{state | published: latest, next_at: now + @interval_ms}, latest}
    else
      {state, nil}
    end
  end

  def collect(state, facts), do: %{state | latest: Map.merge(state.latest, facts)}

  def flush(%{latest: latest, published: published}) when latest != published, do: latest
  def flush(_state), do: nil
end
