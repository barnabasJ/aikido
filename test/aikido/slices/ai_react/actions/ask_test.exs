defmodule Aikido.Slices.AiReact.AskTest do
  use ExUnit.Case, async: true
  alias Aikido.Slices.AiReact.Directives.{LLMCall, PrepareTools}
  alias ReqLLM.Context

  defp ask_signal(overrides \\ %{}) do
    data =
      Map.merge(
        %{
          query: "What is 1 + 1?",
          request_id: "req_test_1",
          model: "anthropic:claude-haiku-4-5-20251001",
          tools: [:test_add],
          system_prompt: "You are precise.",
          max_iterations: 4,
          llm_opts: [max_tokens: 64]
        },
        overrides
      )

    Jido.Signal.new!("ai.react.ask", data)
  end

  defp idle_slice do
    %{
      status: :idle,
      request_id: nil,
      context: nil,
      iteration: 0,
      max_iterations: 10,
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: nil,
      model: nil,
      tools: [],
      llm_opts: []
    }
  end

  test "transitions an idle slice to :setup and prepares tools before the model call" do
    {:ok, %Aikido.ActionResult{state: new_slice, directives: [directive]}} =
      then(ask_signal(), fn signal ->
        Aikido.Slices.AiReact
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, idle_slice()),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert new_slice.status == :setup
    assert new_slice.request_id == "req_test_1"
    assert new_slice.iteration == 0
    assert new_slice.max_iterations == 4
    assert new_slice.model == "anthropic:claude-haiku-4-5-20251001"
    assert new_slice.tools == [:test_add]
    assert new_slice.llm_opts == [max_tokens: 64]
    assert new_slice.result == nil
    assert new_slice.error == nil
    assert new_slice.pending_tool_calls == []
    assert new_slice.tool_results_received == []
    assert new_slice.previous_tool_signature == nil
    messages = Context.to_list(new_slice.context)
    assert length(messages) == 2
    assert Enum.at(messages, 0).role == :system
    assert Enum.at(messages, 1).role == :user

    assert %PrepareTools{} = directive

    assert [
             %LLMCall{
               model: "anthropic:claude-haiku-4-5-20251001",
               request_id: "req_test_1",
               llm_opts: [max_tokens: 64]
             }
           ] = new_slice.tool_preparation

    assert hd(new_slice.tool_preparation).context == new_slice.context
  end

  test "omits the system message when no system_prompt is given" do
    {:ok, %Aikido.ActionResult{state: new_slice, directives: [_]}} =
      then(ask_signal(%{system_prompt: nil}), fn signal ->
        Aikido.Slices.AiReact
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, idle_slice()),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    messages = Context.to_list(new_slice.context)
    assert length(messages) == 1
    assert hd(messages).role == :user
  end

  test "clears prior result/error when reopening a terminated slice" do
    slice =
      idle_slice()
      |> Map.merge(%{
        status: :completed,
        result: "prior",
        error: nil,
        request_id: "req_old",
        previous_tool_signature: "stale",
        pending_tool_calls: [%{id: "stale"}],
        tool_results_received: [%{id: "stale"}]
      })

    {:ok, %Aikido.ActionResult{state: new_slice, directives: [_]}} =
      then(ask_signal(), fn signal ->
        Aikido.Slices.AiReact
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert new_slice.status == :setup
    assert new_slice.result == nil
    assert new_slice.error == nil
    assert new_slice.previous_tool_signature == nil
    assert new_slice.pending_tool_calls == []
    assert new_slice.tool_results_received == []
  end

  test "rejects a concurrent ask while the slice is :running" do
    slice = %{idle_slice() | status: :running, request_id: "req_inflight"}

    assert {:error, %Ash.Error.Unknown{}} =
             then(ask_signal(), fn signal ->
               Aikido.Slices.AiReact
               |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, slice),
                 context: %{aikido: Map.put(%{}, :signal, signal)},
                 skip_unknown_inputs: [:*]
               )
               |> Ash.run_action()
             end)
  end

  test "accepts the ask when the slice is nil (uninitialized)" do
    {:ok, %Aikido.ActionResult{state: %{status: :setup}, directives: [%PrepareTools{}]}} =
      then(ask_signal(), fn signal ->
        Aikido.Slices.AiReact
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, nil),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)
  end
end
