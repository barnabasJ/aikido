defmodule Aikido.AiReact.Actions.TodoChangedTest do
  @moduledoc """
  The waiting-continuation regression for the TodoChanged wrapper.

  The transition-local output reports exactly the genuine conversation
  entries: the internal continuation nudge is run plumbing (marker-excluded
  at the seam, model-visible but never transcript), while real queued user
  text and queued hook context flushed by the planning path ARE transcript
  and must appear, in order.
  """

  use ExUnit.Case, async: true

  @hook_text "[Hook context: delivery gate]\napproved evidence"

  defp blocking_open_todo do
    %{id: "work", text: "provide proof", status: :pending, blocking?: true}
  end

  defp waiting_run(overrides \\ %{}) do
    base = %{
      status: :waiting,
      request_id: "req_todo_changed",
      iteration: 1,
      result: "waiting",
      model: "offline",
      context: ReqLLM.Context.new([ReqLLM.Context.user("wait for evidence")]),
      prepared_tools: {[], %{}},
      options: %{completion: :todos, todo_continuation: :continue},
      queued_messages: ["Worker evidence arrived"],
      hook_context: [%{name: "delivery gate", text: "approved evidence"}]
    }

    AikidoTest.SliceState.new(Aikido.AiReact.Slice, Map.merge(base, overrides))
  end

  defp run_todo_changed(state) do
    Aikido.AiReact.Slice
    |> Ash.ActionInput.for_action(:todo_changed, %{state: state},
      context: %{aikido: %{agent: %{state: %{todos: %{items: [blocking_open_todo()]}}}}},
      skip_unknown_inputs: [:*]
    )
    |> Ash.run_action()
  end

  defp text(message), do: Enum.map_join(message.content, "", &(&1.text || ""))

  defp internal_prompt?(%ReqLLM.Message{metadata: %{aikido_internal_prompt: true}}), do: true
  defp internal_prompt?(%ReqLLM.Message{metadata: %{"aikido_internal_prompt" => true}}), do: true
  defp internal_prompt?(_message), do: false

  test "the waiting continuation reports genuine queued/hook content and omits the internal nudge" do
    assert {:ok, %Aikido.Types.ActionResult{} = result} = run_todo_changed(waiting_run())

    accepted = result.outputs.accepted_messages
    texts = Enum.map(accepted, &text/1)

    # The internal nudge never enters the accepted window.
    refute Enum.any?(accepted, &internal_prompt?/1)
    refute Enum.any?(texts, &(&1 =~ "Continue the remaining work"))

    # Real queued/hook content flushed by the planning path IS transcript,
    # in flush order (queued text before its hook context).
    assert "Worker evidence arrived" in texts
    assert @hook_text in texts

    assert Enum.find_index(texts, &(&1 == "Worker evidence arrived")) <
             Enum.find_index(texts, &(&1 == @hook_text))

    # The prompt stayed model-visible while never becoming transcript.
    context_texts = Enum.map(result.changes.context.messages, &text/1)
    assert Enum.any?(context_texts, &(&1 =~ "Continue the remaining work"))

    # The transition planned the next model turn and consumed its queues.
    assert [%Aikido.AiReact.Directives.LLMCall{}] = result.directives
    assert result.changes.status == :running
    assert result.changes.todo_continuations == 1
    assert result.changes.queued_messages == []
    assert result.changes.hook_context == []
  end

  test "a waiting continuation without queued or hook content reports nothing" do
    state =
      waiting_run(%{
        request_id: "req_todo_changed_silent",
        queued_messages: [],
        hook_context: []
      })

    assert {:ok, %Aikido.Types.ActionResult{} = result} = run_todo_changed(state)

    # Only the marker-excluded internal nudge was appended: the output is
    # silent, exactly like a stale/no-op transition.
    assert result.outputs == %{}
    assert result.changes.status == :running
    assert result.changes.todo_continuations == 1
  end
end
