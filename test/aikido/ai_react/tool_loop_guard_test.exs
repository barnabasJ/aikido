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

  test "a failed or mixed batch leaves successful history intact" do
    state = state(%{max_repeated_tool_cycles: 2, max_consecutive_tool_errors: 3})
    first = batch(state, "a")
    failed = batch(first, "ignored", true)
    assert failed.tool_batch_history == ["a"]
    assert failed.tool_error_streak == 1
    assert failed.status == :running
    repeated = batch(failed, "a")
    assert repeated.error == {:tool_cycle_limit, 1, 2}
    assert repeated.tool_error_streak == 0

    mixed =
      %{first | tool_results_received: [%{error?: false}, %{error?: true}]}
      |> Aikido.AiReact.ToolLoopGuard.record_batch(nil)

    assert mixed.tool_batch_history == ["a"]
    assert mixed.tool_error_streak == 1
  end

  test "consecutive mixed or failed batches use the independent error limit" do
    options = %{max_repeated_tool_cycles: 2, max_consecutive_tool_errors: 2}
    first = state(options) |> batch("a")

    mixed =
      %{first | tool_results_received: [%{error?: false}, %{error?: true}]}
      |> Aikido.AiReact.ToolLoopGuard.record_batch(nil)

    failed = batch(mixed, "ignored", true)
    assert failed.error == {:tool_error_limit, 2}
    assert failed.tool_batch_history == ["a"]
  end

  test "periods one through four warn once at the third complete cycle" do
    for period <- 1..4 do
      cycle = Enum.map(1..period, &"key-#{&1}")

      {final, warnings} =
        Enum.reduce(1..(period * 10), {state(%{}), []}, fn index, {before, warnings} ->
          after_batch = batch(before, Enum.at(cycle, rem(index - 1, period)))

          warnings =
            if Aikido.AiReact.ToolLoopGuard.warning_due?(
                 before.tool_batch_history,
                 after_batch.tool_batch_history
               ), do: warnings ++ [index], else: warnings

          {after_batch, warnings}
        end)

      assert warnings == [period * 3]
      assert length(final.tool_batch_history) <= 16

      assert %{period: ^period, repetitions: repetitions} =
               Aikido.AiReact.ToolLoopGuard.cycle_progress(final.tool_batch_history, 3)

      assert repetitions >= 4
    end
  end

  test "phase shifted histories count complete suffix cycles and choose the smallest qualifying period" do
    for period <- 1..4 do
      cycle = Enum.map(1..period, &"key-#{&1}")
      history = (["prefix"] ++ List.duplicate(cycle, 3)) |> List.flatten()
      assert Aikido.AiReact.ToolLoopGuard.cycle_progress(Enum.drop(history, -1), 3) == nil

      assert %{period: ^period, repetitions: 3} =
               Aikido.AiReact.ToolLoopGuard.cycle_progress(history, 3)
    end

    assert %{period: 1, repetitions: 8} =
             Aikido.AiReact.ToolLoopGuard.cycle_progress(List.duplicate("a", 8), 3)

    assert %{period: 4, repetitions: 3} =
             Aikido.AiReact.ToolLoopGuard.cycle_progress(
               List.duplicate(["a", "a", "b", "b"], 3) |> List.flatten(),
               3
             )
  end

  test "five-cycle termination remains independent of third-cycle warnings" do
    for period <- 1..4 do
      cycle = Enum.map(1..period, &"key-#{&1}")

      final =
        Enum.reduce(1..(period * 5), state(%{max_repeated_tool_cycles: 5}), fn index, before ->
          after_batch = batch(before, Enum.at(cycle, rem(index - 1, period)))
          if index < period * 5, do: assert(after_batch.status == :running)
          after_batch
        end)

      assert final.error == {:tool_cycle_limit, period, 5}
    end
  end

  test "invalid helper inputs fail explicitly and native options reject invalid limits" do
    for {history, minimum} <- [{nil, 3}, {[nil], 3}, {[], 1}, {[], 101}] do
      assert_raise ArgumentError, fn ->
        Aikido.AiReact.ToolLoopGuard.cycle_progress(history, minimum)
      end
    end

    for limit <- [1, 101, :invalid] do
      assert {:error, _} = Aikido.AiReact.Options.new(%{max_repeated_tool_cycles: limit})
    end
  end
end
