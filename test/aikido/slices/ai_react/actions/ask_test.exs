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

    Aikido.Signal.new!("ai.react.ask", data)
  end

  defp idle_slice do
    AikidoTest.SliceState.new(Aikido.Slices.AiReact, %{
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
    })
  end

  test "initialization and mount configuration enforce positive iteration budgets" do
    for invalid <- [0, -1] do
      assert {:error, _} =
               Aikido.Ash.Slice.Config.resolve_config(Aikido.Slices.AiReact, %{
                 max_iterations: invalid
               })

      assert {:error, _} =
               Aikido.Slices.AiReact
               |> Ash.Changeset.for_create(:create, %{max_iterations: invalid})
               |> Ash.Changeset.apply_attributes()
    end

    assert {:ok, %{max_iterations: 1}} =
             Aikido.Ash.Slice.Config.resolve_config(Aikido.Slices.AiReact, %{max_iterations: 1})

    assert {:ok, %{max_iterations: 10}} =
             Aikido.Ash.Slice.Config.resolve_config(Aikido.Slices.AiReact)
  end

  test "transitions an idle slice to :setup and prepares tools before the model call" do
    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: [directive]}} =
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
    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: [_]}} =
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

    {:ok, %Aikido.Types.ActionResult{state: new_slice, directives: [_]}} =
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

  test "requires initialized state before opening a run" do
    input =
      Ash.ActionInput.for_action(
        Aikido.Slices.AiReact,
        :ask,
        Map.put(ask_signal().data, :state, nil)
      )

    refute input.valid?
    assert Enum.any?(input.errors, &(&1.field == :state))
  end

  test "native module contracts accept loaded modules and reject unknown modules before setup" do
    for client <- [ReqLLM.Generation, __MODULE__] do
      input =
        Ash.ActionInput.for_action(
          Aikido.Slices.AiReact,
          :ask,
          Map.merge(ask_signal().data, %{state: idle_slice(), client: client})
        )

      assert input.valid?
      assert input.arguments.client == client

      assert %{client: ^client} =
               Aikido.Ash.Slice.Config.resolve_config!(Aikido.Slices.AiReact, %{client: client})
    end

    invalid =
      Ash.ActionInput.for_action(
        Aikido.Slices.AiReact,
        :ask,
        Map.merge(ask_signal().data, %{state: idle_slice(), client: AikidoTest.NonexistentClient})
      )

    refute invalid.valid?

    assert_raise ArgumentError, fn ->
      Aikido.Ash.Slice.Config.resolve_config!(Aikido.Slices.AiReact, %{
        client: AikidoTest.NonexistentClient
      })
    end

    worker =
      Ash.ActionInput.for_action(Aikido.Slices.AiWorker, :accept, %{
        state: %{},
        task_id: "task",
        member: :worker,
        attempt: "attempt",
        reply_to: self(),
        text: "work",
        client: AikidoTest.NonexistentClient
      })

    refute worker.valid?
  end
end
