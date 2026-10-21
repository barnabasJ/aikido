defmodule Aikido.AiReact.EventGatesTest do
  use ExUnit.Case, async: true

  alias Aikido.AiReact.Directives.{ExecuteHook, LLMCall}
  alias Aikido.AiReact.Hooks.{Decision, Hook}

  defp state(overrides) do
    AikidoTest.SliceState.new(
      Aikido.AiReact.Slice,
      Map.merge(
        %{
          status: :running,
          request_id: "current",
          model: "offline",
          context: ReqLLM.Context.new(),
          prepared_tools: {[], %{}}
        },
        overrides
      )
    )
  end

  defp run(action, state, data) do
    signal = Aikido.Signal.new!("ai.react.test", data)

    Aikido.AiReact.Slice
    |> Ash.ActionInput.for_action(action, Map.put(data, :state, state),
      context: %{aikido: %{signal: signal}}
    )
    |> Ash.run_action!()
  end

  defp tool_result(state, id) do
    run(:tool_result, state, %{
      request_id: "current",
      tool_call_id: id,
      name: id,
      content: "result #{id}"
    })
  end

  defp complete(state, token, decision) do
    run(:hook_completed, state, %{
      request_id: "current",
      token: token,
      name: "approval",
      mode: :sync,
      result: {:ok, decision}
    })
  end

  defp parallel_results do
    {:ok, hook} =
      Ash.Type.cast_input(Hook, %{
        name: "approval",
        event: :after_tool,
        script: "return nil"
      })

    calls = for id <- ["one", "two"], do: %{id: id, name: id, arguments: %{}}

    state =
      state(%{
        hooks: [hook],
        pending_tool_calls: calls,
        iteration: 1,
        context: ReqLLM.Context.new([ReqLLM.Context.assistant("", tool_calls: calls)])
      })

    first = tool_result(state, "one")
    assert [%ExecuteHook{token: token}] = first.directives
    second = tool_result(first.state, "two")
    assert second.directives == []
    assert Map.keys(second.state.hooks_pending) == [token]
    assert second.state.pending_tool_calls == []
    {second.state, token}
  end

  test "cancellation uses native cast request correlation for atom and string payload keys" do
    for status <- [:setup, :running, :waiting],
        key <- [:request_id, "request_id"],
        requested <- ["obsolete", "current", nil] do
      original = state(%{status: status, queued_messages: ["next message"]})
      result = run(:cancel, original, %{key => requested})

      if requested == "obsolete" do
        assert result.state == original
      else
        assert result.state.status == :failed
        assert result.state.error == :cancelled
      end

      assert result.state.queued_messages == ["next message"]
      assert result.directives == []
      assert result == run(:cancel, original, %{key => requested})
    end
  end

  test "parallel results serialize synchronous gates and denial prevents the next model" do
    {waiting, token} = parallel_results()
    # A later gate has not been launched and cannot release the queued continuation.
    ignored = complete(waiting, token + 1, %Decision{context: "too early"})
    assert ignored.state == waiting
    assert ignored.directives == []

    denied = complete(waiting, token, %Decision{decision: :deny, message: "blocked"})
    assert denied.state.status == :failed
    assert denied.state.error == {:hook_denied, "approval", "blocked"}
    assert denied.state.hooks_pending == %{}
    assert denied.directives == []
    assert denied == complete(waiting, token, %Decision{decision: :deny, message: "blocked"})
  end

  test "omitting the optional cancellation request ID cancels the current run" do
    for status <- [:setup, :running, :waiting] do
      result = run(:cancel, state(%{status: status}), %{})
      assert result.state.status == :failed
      assert result.state.error == :cancelled
      assert result.directives == []
    end
  end

  test "both synchronous approvals contribute context before the model is released" do
    {waiting, token} = parallel_results()
    first = complete(waiting, token, %Decision{context: "first approval"})
    assert [%ExecuteHook{token: second_token, event: %{tool_call_id: "two"}}] = first.directives
    assert second_token > token
    assert first.state.status == :running

    second = complete(first.state, second_token, %Decision{context: "second approval"})
    assert [%LLMCall{} = model] = second.directives
    assert second.state.hooks_pending == %{}
    assert second.state.hook_context == []
    assert model.context == second.state.context

    text =
      model.context
      |> ReqLLM.Context.to_list()
      |> Enum.flat_map(& &1.content)
      |> Enum.map_join("\n", &(&1.text || ""))

    assert text =~ "first approval"
    assert text =~ "second approval"
    assert second == complete(first.state, second_token, %Decision{context: "second approval"})
  end

  test "a later synchronous denial and cancellation discard queued model work" do
    for outcome <- [:deny, :cancel] do
      {waiting, token} = parallel_results()
      first = complete(waiting, token, %Decision{})
      assert [%ExecuteHook{token: second_token}] = first.directives

      result =
        case outcome do
          :deny ->
            complete(first.state, second_token, %Decision{decision: :deny, message: "second"})

          :cancel ->
            run(:cancel, first.state, %{"request_id" => "current"})
        end

      assert result.state.status == :failed
      assert result.state.hooks_pending == %{}
      assert result.directives == []
      late = complete(result.state, second_token, %Decision{})
      assert late.state == result.state
      assert late.directives == []
    end
  end
end
