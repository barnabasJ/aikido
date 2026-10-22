defmodule Aikido.ToolLoopGuardTest do
  use ExUnit.Case, async: true

  defp state(options) do
    %{
      status: :running,
      error: nil,
      tool_error_streak: 0,
      tool_batch_history: [],
      tool_results_received: [],
      options: Aikido.AiReact.Options.new!(options)
    }
  end

  defp batch(state, signature, failed? \\ false) do
    state
    |> Map.put(:tool_results_received, [%{error?: failed?}])
    |> Aikido.AiReact.ToolLoopGuard.record_batch(signature)
  end

  test "guards are disabled by default and successful batches reset the error streak" do
    state = state(%{}) |> batch("a", true) |> batch("a", true)
    assert state.status == :running
    assert state.tool_error_streak == 2
    assert batch(state, "b").tool_error_streak == 0
  end

  test "consecutive failing batches stop at the configured limit" do
    state = state(%{max_consecutive_tool_errors: 2}) |> batch("a", true) |> batch("b", true)
    assert state.status == :failed
    assert state.error == {:tool_error_limit, 2}
  end

  test "alternating cycles stop while nonrepeating batches remain runnable" do
    state = state(%{max_repeated_tool_cycles: 2}) |> batch("a") |> batch("b") |> batch("a")
    assert state.status == :running
    assert batch(state, "b").error == {:tool_cycle_limit, 2, 2}
    assert batch(state, "c").status == :running
  end
end
