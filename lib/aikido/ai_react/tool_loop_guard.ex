defmodule Aikido.AiReact.ToolLoopGuard do
  @moduledoc "Pure, optional bounds on consecutive tool errors and repeating successful input/result cycles."

  @doc "Record a successful signature or a failed batch and enforce independent limits."
  @spec record_batch(state :: map(), signature :: String.t() | nil) :: map()
  def record_batch(state, signature) do
    failed? = Enum.any?(state.tool_results_received, &Map.get(&1, :error?, false))
    errors = if failed?, do: state.tool_error_streak + 1, else: 0

    limit = state.options.max_repeated_tool_cycles

    history =
      if failed?,
        do: state.tool_batch_history,
        else: Enum.take(state.tool_batch_history ++ [signature], -max((limit || 4) * 4, 16))

    state = %{state | tool_error_streak: errors, tool_batch_history: history}
    cycle = if limit && !failed?, do: cycle_progress(history, limit)

    cond do
      state.options.max_consecutive_tool_errors &&
          errors >= state.options.max_consecutive_tool_errors ->
        %{state | status: :failed, error: {:tool_error_limit, errors}}

      cycle ->
        %{
          state
          | status: :failed,
            error: {:tool_cycle_limit, cycle.period, limit}
        }

      true ->
        state
    end
  end

  @doc "Return the smallest repeating period (one to four batches) and complete suffix cycles, or nil."
  @spec cycle_progress([String.t()], pos_integer()) ::
          %{period: pos_integer(), repetitions: pos_integer()} | nil
  def cycle_progress(history, minimum_repetitions \\ 2)

  def cycle_progress(history, minimum_repetitions)
      when is_list(history) and is_integer(minimum_repetitions) and minimum_repetitions in 2..100 do
    unless Enum.all?(history, &is_binary/1),
      do: raise(ArgumentError, "cycle history must contain string fingerprints")

    Enum.find_value(1..4, fn period ->
      repetitions = completed_cycles(history, period)

      if repetitions >= minimum_repetitions,
        do: %{period: period, repetitions: repetitions}
    end)
  end

  def cycle_progress(_history, _minimum_repetitions) do
    raise ArgumentError,
          "cycle history must be a list and minimum repetitions must be between 2 and 100"
  end

  @doc "Warn once when successful history first reaches three complete repetitions of a period."
  @spec warning_due?([String.t()], [String.t()]) :: boolean()
  def warning_due?(before_history, after_history) do
    case cycle_progress(after_history, 3) do
      %{period: period, repetitions: 3} -> completed_cycles(before_history, period) < 3
      _ -> false
    end
  end

  defp completed_cycles(history, period) do
    reversed = Enum.reverse(history)
    cycle = Enum.take(reversed, period)

    if length(cycle) == period do
      reversed
      |> Enum.chunk_every(period)
      |> Enum.take_while(&(&1 == cycle))
      |> length()
    else
      0
    end
  end
end
