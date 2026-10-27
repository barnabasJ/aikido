defmodule Aikido.AiReact.FailedTest do
  use ExUnit.Case, async: true

  defp signal(request_id, reason) do
    Aikido.Signal.new!("ai.react.failed", %{reason: reason, request_id: request_id})
  end

  defp running_slice(request_id) do
    AikidoTest.SliceState.new(Aikido.AiReact.Slice, %{
      status: :running,
      request_id: request_id,
      context: nil,
      iteration: 1,
      max_iterations: 4,
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: nil,
      model: nil,
      tools: [],
      llm_opts: []
    })
  end

  test "settles a matching :running slice to :failed and stores the reason" do
    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: []}} =
      then(signal("req_match", :rate_limited), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(
          :failed,
          Map.put(signal.data || %{}, :state, running_slice("req_match")),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert new_slice.status == :failed
    assert new_slice.error == :rate_limited
  end

  test "drops stale signals — request_id mismatch leaves the slice untouched" do
    slice = running_slice("req_active")

    {:ok, %Aikido.Types.ActionResult{state: returned_slice, directives: []}} =
      then(signal("req_old", :anything), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:failed, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert AikidoTest.SliceState.attributes(returned_slice) ==
             AikidoTest.SliceState.attributes(slice)
  end

  test "drops the signal when the slice has already terminated" do
    slice = %{running_slice("req_done") | status: :completed, result: "earlier answer"}

    {:ok, %Aikido.Types.ActionResult{state: returned_slice, directives: []}} =
      then(signal("req_done", :late), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:failed, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert AikidoTest.SliceState.attributes(returned_slice) ==
             AikidoTest.SliceState.attributes(slice)
  end
end
