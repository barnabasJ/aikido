defmodule Aikido.AiReact.ToolLoopGuard do
  @moduledoc "Pure, optional bounds on consecutive tool errors and repeating one-to-four-batch cycles."

  @doc "Record one completed batch and fail the run only when an enabled guard reaches its limit."
  def record_batch(state, signature) do
    errors =
      if Enum.any?(state.tool_results_received, &Map.get(&1, :error?, false)),
        do: state.tool_error_streak + 1,
        else: 0

    limit = state.options.max_repeated_tool_cycles
    history = Enum.take(state.tool_batch_history ++ [signature], -max((limit || 2) * 4, 8))
    state = %{state | tool_error_streak: errors, tool_batch_history: history}
    period = if limit, do: repeated_period(history, limit)

    cond do
      state.options.max_consecutive_tool_errors &&
          errors >= state.options.max_consecutive_tool_errors ->
        %{state | status: :failed, error: {:tool_error_limit, errors}}

      period ->
        %{
          state
          | status: :failed,
            error: {:tool_cycle_limit, period, limit}
        }

      true ->
        state
    end
  end

  defp repeated_period(history, repeats) do
    Enum.find(1..4, fn period ->
      tail = Enum.take(history, -(period * repeats))

      length(tail) == period * repeats &&
        tail |> Enum.chunk_every(period) |> Enum.uniq() |> length() == 1
    end)
  end
end
