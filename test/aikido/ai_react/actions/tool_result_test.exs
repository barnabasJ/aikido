defmodule Aikido.AiReact.ToolResultTest.Keys do
  def inputs(batch, tag),
    do: {:ok, {tag, Enum.map(batch, fn {name, arguments, _content} -> {name, arguments} end)}}

  def full(batch), do: {:ok, batch}

  def expect_batch(batch, expected) do
    if batch == expected, do: {:ok, batch}, else: {:error, :unexpected_batch}
  end

  def fail(_batch), do: {:error, :comparison_unavailable}
  def invalid(_batch), do: :not_a_key_result
  def raise_error(_batch), do: raise(ArgumentError, "comparison failed")
  def throw_error(_batch), do: throw(:comparison_failed)
end

defmodule Aikido.AiReact.ToolResultTest do
  use ExUnit.Case, async: true

  alias Aikido.AiReact.Directives.LLMCall
  alias ReqLLM.Context

  defp slice_with_pending(calls, opts \\ []) do
    AikidoTest.SliceState.new(Aikido.AiReact.Slice, %{
      status: :running,
      prepared_tools: {[], %{}},
      request_id: Keyword.get(opts, :request_id, "req_1"),
      context: Keyword.get(opts, :context, Context.new([Context.user("hi")])),
      iteration: Keyword.get(opts, :iteration, 1),
      max_iterations: 4,
      result: nil,
      error: nil,
      pending_tool_calls: calls,
      tool_results_received: [],
      previous_tool_signature: Keyword.get(opts, :previous_tool_signature, nil),
      model: "anthropic:claude-haiku-4-5-20251001",
      tools: [:test_add],
      llm_opts: []
    })
  end

  defp signal(request_id, tool_call_id, name, content) do
    Aikido.Signal.new!("ai.react.tool.completed", %{
      request_id: request_id,
      tool_call_id: tool_call_id,
      name: name,
      content: content
    })
  end

  test "appends a result to the context but does not emit until the batch is full" do
    calls = [
      %{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}},
      %{id: "call_2", name: "test_add", arguments: %{"a" => 3, "b" => 4}}
    ]

    slice = slice_with_pending(calls)

    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: directives}} =
      then(signal("req_1", "call_1", "test_add", "{\"result\":3}"), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:tool_result, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert directives == []
    assert length(new_slice.tool_results_received) == 1
    assert new_slice.pending_tool_calls == calls
    messages = Context.to_list(new_slice.context)
    assert List.last(messages).role == :tool
  end

  test "emits the next LLMCall when all results are in" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = slice_with_pending(calls)

    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: [%LLMCall{} = directive]}} =
      then(signal("req_1", "call_1", "test_add", "{\"result\":3}"), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:tool_result, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert new_slice.pending_tool_calls == []
    assert new_slice.tool_results_received == []
    assert is_binary(new_slice.previous_tool_signature)
    assert directive.context == new_slice.context
    assert directive.model == slice.model
    assert directive.tools == elem(slice.prepared_tools, 0)

    assert new_slice.estimated_tokens ==
             Aikido.AiReact.Conversation.estimate_tokens(new_slice.context)

    assert directive.request_id == slice.request_id
    assert directive.llm_opts == slice.llm_opts
  end

  test "appends the cycle warning when the batch repeats the previous signature" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]

    first_result =
      Aikido.AiReact.Slice
      |> Ash.ActionInput.for_action(:tool_result, %{
        state: slice_with_pending(calls),
        request_id: "req_1",
        tool_call_id: "call_1",
        name: "test_add",
        content: "{\"result\":3}"
      })
      |> Ash.run_action!()

    slice = %{first_result.state | pending_tool_calls: calls}

    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: [%LLMCall{} = directive]}} =
      then(signal("req_1", "call_1", "test_add", "{\"result\":3}"), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:tool_result, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    messages = Context.to_list(new_slice.context)
    last = List.last(messages)
    assert last.role == :user
    text = last.content |> hd() |> Map.get(:text)
    assert text =~ "Do NOT repeat this pattern"
    assert directive.context == new_slice.context
  end

  test "does not append the cycle warning on the first tool batch" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = slice_with_pending(calls, previous_tool_signature: nil)

    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: [%LLMCall{}]}} =
      then(signal("req_1", "call_1", "test_add", "{\"result\":3}"), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:tool_result, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    messages = Context.to_list(new_slice.context)
    refute List.last(messages).role == :user
  end

  test "drops stale signals — request_id mismatch" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = slice_with_pending(calls, request_id: "req_active")

    {:ok, %Aikido.Types.ActionResult{state: returned, directives: []}} =
      then(signal("req_old", "call_1", "test_add", "{}"), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:tool_result, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert AikidoTest.SliceState.attributes(returned) == AikidoTest.SliceState.attributes(slice)
  end

  test "batch fingerprints stay fixed-size for large arguments and outputs" do
    signature = completed_signature(%{"text" => String.duplicate("input", 20_000)})

    assert signature =~ ~r/\A[0-9a-f]{64}\z/
    assert byte_size(signature) == byte_size(completed_signature(%{"text" => "small"}))

    refute signature ==
             completed_signature(%{"text" => String.duplicate("input", 20_000)}, "other output")
  end

  test "changed useful output avoids a repeat warning and a cycle limit" do
    calls = [%{id: "first", name: "test_add", arguments: %{"item" => 1}}]

    start = %{
      slice_with_pending(calls)
      | options: Aikido.AiReact.Options.new!(%{max_repeated_tool_cycles: 2})
    }

    first = complete_batch(start, [{"first", "old", false}])
    next = %{first | pending_tool_calls: [%{hd(calls) | id: "second"}]}
    second = complete_batch(next, [{"second", "new", false}])
    assert second.status == :running
    refute second.previous_tool_signature == first.previous_tool_signature
    assert length(second.tool_batch_history) == 2

    refute Enum.any?(Context.to_list(second.context), fn message ->
             message.role == :user &&
               Enum.any?(message.content, &(Map.get(&1, :text, "") =~ "Do NOT repeat"))
           end)
  end

  test "fresh call IDs do not hide identical calls and results" do
    calls = [%{id: "first", name: "test_add", arguments: %{"item" => 1}}]

    start = %{
      slice_with_pending(calls)
      | options: Aikido.AiReact.Options.new!(%{max_repeated_tool_cycles: 2})
    }

    first = complete_batch(start, [{"first", "same", false}])
    next = %{first | pending_tool_calls: [%{hd(calls) | id: "second"}]}
    second = complete_batch(next, [{"second", "same", false}])
    assert second.previous_tool_signature == first.previous_tool_signature
    assert second.error == {:tool_cycle_limit, 1, 2}
    assert List.last(Context.to_list(second.context)).role == :user
  end

  test "out-of-order results join their own call IDs before sorting" do
    calls = [
      %{id: "a", name: "test_add", arguments: %{"item" => 1}},
      %{id: "b", name: "test_add", arguments: %{"item" => 2}}
    ]

    first = complete_batch(slice_with_pending(calls), [{"b", "two", false}, {"a", "one", false}])
    next_calls = [%{Enum.at(calls, 0) | id: "c"}, %{Enum.at(calls, 1) | id: "d"}]
    next = %{first | pending_tool_calls: next_calls}
    second = complete_batch(next, [{"c", "one", false}, {"d", "two", false}])
    assert second.previous_tool_signature == first.previous_tool_signature
  end

  test "duplicate equivalent calls are counted rather than deduplicated" do
    calls = [
      %{id: "a", name: "test_add", arguments: %{"item" => 1}},
      %{id: "b", name: "test_add", arguments: %{"item" => 1}}
    ]

    duplicated =
      complete_batch(
        slice_with_pending(calls),
        [{"b", "one", false}, {"a", "one", false}]
      )

    refute duplicated.previous_tool_signature == completed_signature(%{"item" => 1}, "one")
  end

  test "failed mixed batch preserves the previous successful fingerprint" do
    first_call = %{id: "a", name: "test_add", arguments: %{"item" => 1}}
    first = complete_batch(slice_with_pending([first_call]), [{"a", "same", false}])
    mixed_calls = [%{first_call | id: "b"}, %{first_call | id: "c"}]

    mixed =
      complete_batch(
        %{first | pending_tool_calls: mixed_calls},
        [{"c", "failed", true}, {"b", "same", false}]
      )

    assert mixed.previous_tool_signature == first.previous_tool_signature
    assert mixed.tool_batch_history == first.tool_batch_history
    assert mixed.tool_error_streak == 1
    refute List.last(Context.to_list(mixed.context)).role == :user

    repeated =
      complete_batch(
        %{mixed | pending_tool_calls: [%{first_call | id: "d"}]},
        [{"d", "same", false}]
      )

    assert repeated.previous_tool_signature == first.previous_tool_signature
    assert repeated.tool_error_streak == 0
    assert List.last(Context.to_list(repeated.context)).role == :user
  end

  test "fingerprints compare complete arguments rather than truncated inspected text" do
    prefix = Enum.to_list(1..100)

    refute completed_signature(%{"values" => prefix ++ [101]}) ==
             completed_signature(%{"values" => prefix ++ [102]})

    assert completed_signature(%{"a" => 1, "b" => 2}) ==
             completed_signature(Map.new([{"b", 2}, {"a", 1}]))
  end

  defp completed_signature(arguments, content \\ String.duplicate("output", 20_000)) do
    calls = [%{id: "call_1", name: "test_add", arguments: arguments}]

    result =
      Aikido.AiReact.Slice
      |> Ash.ActionInput.for_action(:tool_result, %{
        state: slice_with_pending(calls),
        request_id: "req_1",
        tool_call_id: "call_1",
        name: "test_add",
        content: content
      })
      |> Ash.run_action!()

    assert result.state.tool_batch_history == [result.state.previous_tool_signature]
    result.state.previous_tool_signature
  end

  test "a configured key may ignore changing output while preserving the native cycle limit" do
    keys = Aikido.AiReact.ToolResultTest.Keys
    calls = [%{id: "first", name: "test_add", arguments: %{"item" => 1}}]

    options =
      Aikido.AiReact.Options.new!(%{
        tool_loop_key: {keys, :inputs, ["policy"]},
        max_repeated_tool_cycles: 2
      })

    first =
      complete_batch(%{slice_with_pending(calls) | options: options}, [{"first", "old", false}])

    second =
      complete_batch(
        %{first | pending_tool_calls: [%{hd(calls) | id: "second"}]},
        [{"second", "changed", false}]
      )

    assert second.previous_tool_signature == first.previous_tool_signature
    assert second.error == {:tool_cycle_limit, 1, 2}
    assert byte_size(second.previous_tool_signature) == 64
    assert length(second.tool_batch_history) == 2
    assert Enum.count(Context.to_list(second.context), &(&1.role == :tool)) == 2
  end

  test "a full-batch callback has exactly the default fingerprint despite result arrival order" do
    keys = Aikido.AiReact.ToolResultTest.Keys

    calls = [
      %{id: "a", name: "test_add", arguments: %{"item" => 1}},
      %{id: "b", name: "test_add", arguments: %{"item" => 2}}
    ]

    default =
      complete_batch(slice_with_pending(calls), [{"b", "two", false}, {"a", "one", false}])

    custom =
      complete_batch(
        %{
          slice_with_pending(Enum.reverse(calls))
          | options: Aikido.AiReact.Options.new!(%{tool_loop_key: {keys, :full, []}})
        },
        [{"a", "one", false}, {"b", "two", false}]
      )

    assert custom.previous_tool_signature == default.previous_tool_signature
  end

  test "the callback receives every duplicate call paired with its own actual content" do
    keys = Aikido.AiReact.ToolResultTest.Keys
    arguments = %{"item" => 1}

    calls = [
      %{id: "a", name: "test_add", arguments: arguments},
      %{id: "b", name: "test_add", arguments: arguments}
    ]

    expected = [{"test_add", arguments, "first"}, {"test_add", arguments, "second"}]
    options = Aikido.AiReact.Options.new!(%{tool_loop_key: {keys, :expect_batch, [expected]}})

    actual =
      complete_batch(
        %{slice_with_pending(calls) | options: options},
        [{"b", "second", false}, {"a", "first", false}]
      )

    default =
      complete_batch(slice_with_pending(calls), [{"a", "first", false}, {"b", "second", false}])

    assert actual.status == :running
    assert actual.previous_tool_signature == default.previous_tool_signature
  end

  test "mixed batches never invoke a configured fail-if-called callback" do
    keys = Aikido.AiReact.ToolResultTest.Keys

    calls = [
      %{id: "a", name: "test_add", arguments: %{a: 1}},
      %{id: "b", name: "test_add", arguments: %{a: 2}}
    ]

    options = Aikido.AiReact.Options.new!(%{tool_loop_key: {keys, :raise_error, []}})

    actual =
      complete_batch(
        %{
          slice_with_pending(calls)
          | options: options,
            tool_batch_history: ["previous"],
            previous_tool_signature: "previous"
        },
        [{"a", "useful", false}, {"b", "failure", true}]
      )

    assert actual.status == :running
    assert actual.error == nil
    assert actual.tool_error_streak == 1
    assert actual.tool_batch_history == ["previous"]
    assert actual.previous_tool_signature == "previous"
    assert Enum.count(Context.to_list(actual.context), &(&1.role == :tool)) == 2
  end

  test "callback errors, exceptions, throws and invalid returns fail explicitly after result adoption" do
    keys = Aikido.AiReact.ToolResultTest.Keys
    calls = [%{id: "a", name: "test_add", arguments: %{}}]

    for function <- [:fail, :raise_error, :throw_error, :invalid, :missing_function] do
      options = Aikido.AiReact.Options.new!(%{tool_loop_key: {keys, function, []}})

      failed =
        complete_batch(%{slice_with_pending(calls) | options: options}, [{"a", "retained", false}])

      assert failed.status == :failed
      assert {:tool_loop_key_failed, {^keys, ^function, _reason}} = failed.error
      assert failed.tool_batch_history == []
      assert failed.previous_tool_signature == nil
      assert failed.pending_tool_calls == []
      assert List.last(Context.to_list(failed.context)).role == :tool
    end
  end

  test "failed batches bypass the comparison callback and retain successful history" do
    keys = Aikido.AiReact.ToolResultTest.Keys
    calls = [%{id: "a", name: "test_add", arguments: %{}}]
    options = Aikido.AiReact.Options.new!(%{tool_loop_key: {keys, :raise_error, []}})

    failed_batch =
      complete_batch(
        %{
          slice_with_pending(calls)
          | options: options,
            tool_batch_history: ["existing"],
            previous_tool_signature: "existing"
        },
        [{"a", "error", true}]
      )

    assert failed_batch.status == :running
    assert failed_batch.tool_error_streak == 1
    assert failed_batch.tool_batch_history == ["existing"]
    assert failed_batch.previous_tool_signature == "existing"
  end

  test "legacy options without the added key retain the exact default comparison" do
    calls = [%{id: "a", name: "test_add", arguments: %{"item" => 1}}]
    current = slice_with_pending(calls)
    expected = complete_batch(current, [{"a", "same", false}])
    # Historical opaque checkpoint representation intentionally lacks the new field.
    legacy = %{current | options: Map.delete(current.options, :tool_loop_key)}
    actual = complete_batch(legacy, [{"a", "same", false}])
    assert actual.previous_tool_signature == expected.previous_tool_signature
    assert actual.status == :running
  end

  test "native options require an MFA rather than a closure or malformed callback" do
    for callback <- [fn _ -> {:ok, :key} end, {:only_module}, {__MODULE__, :key, nil}] do
      assert {:error, _} = Aikido.AiReact.Options.new(%{tool_loop_key: callback})
    end

    assert Aikido.AiReact.Options.new!(%{}).tool_loop_key == nil
  end

  defp complete_batch(state, results) do
    Enum.reduce(results, state, fn {id, content, error?}, current ->
      Aikido.AiReact.Slice
      |> Ash.ActionInput.for_action(:tool_result, %{
        state: current,
        request_id: current.request_id,
        tool_call_id: id,
        name: "test_add",
        content: content,
        error?: error?
      })
      |> Ash.run_action!()
      |> Map.fetch!(:state)
    end)
  end

  test "drops signals that arrive after the slice terminated" do
    calls = [%{id: "call_1", name: "test_add", arguments: %{"a" => 1, "b" => 2}}]
    slice = %{slice_with_pending(calls) | status: :completed, result: "earlier"}

    {:ok, %Aikido.Types.ActionResult{state: returned, directives: []}} =
      then(signal("req_1", "call_1", "test_add", "{}"), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:tool_result, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert AikidoTest.SliceState.attributes(returned) == AikidoTest.SliceState.attributes(slice)
  end
end
