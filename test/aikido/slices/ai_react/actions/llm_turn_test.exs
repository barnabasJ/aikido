defmodule Aikido.Slices.AiReact.LLMTurnTest do
  use ExUnit.Case, async: true
  alias Aikido.Slices.AiReact.Directives.ToolExec

  alias ReqLLM.Context

  defp running_slice(opts \\ []) do
    %{
      status: :running,
      prepared_tools: {[], %{}},
      request_id: Keyword.get(opts, :request_id, "req_1"),
      context: Keyword.get(opts, :context, Context.new([Context.user("hi")])),
      iteration: Keyword.get(opts, :iteration, 0),
      max_iterations: Keyword.get(opts, :max_iterations, 4),
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: Keyword.get(opts, :previous_tool_signature, nil),
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: Keyword.get(opts, :tools, [:test_add]),
      llm_opts: []
    }
  end

  defp signal(request_id, turn) do
    Jido.Signal.new!("ai.react.llm.completed", %{turn: turn, request_id: request_id})
  end

  test "model history retains the canonical assistant message and provider reasoning" do
    for tool_calls <- [[], [%{id: "lookup", name: "test_add", arguments: %{"a" => 1}}]] do
      message =
        ReqLLM.Context.assistant(
          [
            ReqLLM.Message.ContentPart.thinking("reasoning"),
            ReqLLM.Message.ContentPart.text("answer")
          ],
          tool_calls: tool_calls,
          metadata: %{response_id: "provider-response"}
        )
        |> Map.put(:reasoning_details, [
          %ReqLLM.Message.ReasoningDetails{
            text: "reasoning",
            signature: "provider-signature",
            provider: :anthropic
          }
        ])

      response =
        struct!(ReqLLM.Response,
          id: "provider-response",
          model: "offline",
          context: Context.new(),
          message: message,
          finish_reason: if(tool_calls == [], do: :stop, else: :tool_calls)
        )

      assert {:ok, %Aikido.Types.ActionResult{state: state, directives: _directives}} =
               then(signal("req_1", response), fn signal ->
                 Aikido.Slices.AiReact
                 |> Ash.ActionInput.for_action(
                   :llm_turn,
                   Map.put(signal.data || %{}, :state, running_slice()),
                   context: %{aikido: Map.put(%{}, :signal, signal)},
                   skip_unknown_inputs: [:*]
                 )
                 |> Ash.run_action()
               end)

      assert List.last(state.context.messages) == message
      assert state.estimated_tokens == Aikido.AI.Context.estimate_tokens(state.context)
    end
  end

  defp final_turn(text) do
    struct!(ReqLLM.Response,
      id: "scripted",
      model: "offline",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant(text, tool_calls: []),
      finish_reason: :stop
    )
  end

  defp tool_turn(calls, opts \\ []) do
    struct!(ReqLLM.Response,
      id: "scripted",
      model: "offline",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant(Keyword.get(opts, :text, ""), tool_calls: calls),
      finish_reason: :tool_calls
    )
  end

  describe("final answer turn") do
    test "appends the assistant message and settles :completed with the text" do
      {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: directives}} =
        then(signal("req_1", final_turn("42")), fn signal ->
          Aikido.Slices.AiReact
          |> Ash.ActionInput.for_action(
            :llm_turn,
            Map.put(signal.data || %{}, :state, running_slice()),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directives == []
      assert new_slice.status == :completed
      assert new_slice.result == "42"
      assert new_slice.iteration == 1
      messages = Context.to_list(new_slice.context)
      assert List.last(messages).role == :assistant
    end
  end

  describe("tool calls turn") do
    test "stores pending calls, emits one ToolExec per call, increments iteration" do
      calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]

      {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: directives}} =
        then(signal("req_1", tool_turn(calls)), fn signal ->
          Aikido.Slices.AiReact
          |> Ash.ActionInput.for_action(
            :llm_turn,
            Map.put(signal.data || %{}, :state, running_slice()),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert new_slice.status == :running
      assert new_slice.iteration == 1
      assert length(new_slice.pending_tool_calls) == 1
      assert new_slice.tool_results_received == []
      # LLMTurn does NOT update previous_tool_signature — that's ToolResult's job.
      assert new_slice.previous_tool_signature == nil
      assert [%ToolExec{tool_call: tc, registry: %{}, request_id: "req_1"}] = directives
      assert tc.id == "call_1"
      messages = Context.to_list(new_slice.context)
      assistant = List.last(messages)
      assert assistant.role == :assistant
    end

    test "dispatches one ToolExec per parallel tool call" do
      calls = [
        %{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}},
        %{id: "call_2", name: "test_add", arguments: %{"a" => 3, "b" => 4}}
      ]

      {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: directives}} =
        then(signal("req_1", tool_turn(calls)), fn signal ->
          Aikido.Slices.AiReact
          |> Ash.ActionInput.for_action(
            :llm_turn,
            Map.put(signal.data || %{}, :state, running_slice()),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert length(new_slice.pending_tool_calls) == 2
      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%ToolExec{}, &1))
    end

    test "settles :completed (truncated, result nil) when the cap is hit" do
      slice = running_slice(iteration: 3, max_iterations: 4)
      calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]

      {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: directives}} =
        then(signal("req_1", tool_turn(calls)), fn signal ->
          Aikido.Slices.AiReact
          |> Ash.ActionInput.for_action(:llm_turn, Map.put(signal.data || %{}, :state, slice),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directives == []
      assert new_slice.status == :completed
      assert new_slice.result == nil
      assert new_slice.iteration == 4
    end
  end

  describe("stale and post-terminal signals") do
    test "drops a signal whose request_id doesn't match the slice" do
      slice = running_slice(request_id: "req_active")

      {:ok, %Aikido.Types.ActionResult{state: returned, directives: []}} =
        then(signal("req_old", final_turn("ignored")), fn signal ->
          Aikido.Slices.AiReact
          |> Ash.ActionInput.for_action(:llm_turn, Map.put(signal.data || %{}, :state, slice),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert returned == slice
    end

    test "drops a signal that arrives after the slice has already terminated" do
      slice = %{running_slice() | status: :completed, result: "earlier"}

      {:ok, %Aikido.Types.ActionResult{state: returned, directives: []}} =
        then(signal("req_1", final_turn("ignored")), fn signal ->
          Aikido.Slices.AiReact
          |> Ash.ActionInput.for_action(:llm_turn, Map.put(signal.data || %{}, :state, slice),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert returned == slice
    end
  end
end
