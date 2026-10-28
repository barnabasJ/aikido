defmodule Aikido.AiReact.AskTest do
  use ExUnit.Case, async: true
  alias Aikido.AiReact.Directives.PrepareTools
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
    AikidoTest.SliceState.new(Aikido.AiReact.Slice, %{
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
               Aikido.Slice.Config.resolve_config(Aikido.AiReact.Slice, %{
                 max_iterations: invalid
               })

      assert {:error, _} =
               Aikido.AiReact.Slice
               |> Ash.Changeset.for_create(:create, %{max_iterations: invalid})
               |> Ash.create()
    end

    assert {:ok, %{max_iterations: 1}} =
             Aikido.Slice.Config.resolve_config(Aikido.AiReact.Slice, %{max_iterations: 1})

    assert {:ok, %{max_iterations: 10}} =
             Aikido.Slice.Config.resolve_config(Aikido.AiReact.Slice)
  end

  test "transitions an idle slice to :setup and prepares tools before the model call" do
    {:ok, %Aikido.Types.ActionResult{changes: changes, directives: [directive]}} =
      then(ask_signal(), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, idle_slice()),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert changes.status == :setup
    assert changes.request_id == "req_test_1"
    assert changes.iteration == 0
    assert changes.max_iterations == 4
    assert changes.model == "anthropic:claude-haiku-4-5-20251001"
    assert changes.tools == [:test_add]
    assert changes.llm_opts == [max_tokens: 64]
    assert changes.result == nil
    assert changes.error == nil
    assert changes.pending_tool_calls == []
    assert changes.tool_results_received == []
    assert changes.previous_tool_signature == nil
    messages = Context.to_list(changes.context)
    assert length(messages) == 2
    assert Enum.at(messages, 0).role == :system
    assert Enum.at(messages, 1).role == :user

    assert %PrepareTools{} = directive

    assert directive.request_id == changes.request_id
    assert directive.tools == changes.tools
    assert directive.tool_options == changes.tool_options
    assert changes.prepared_tools == nil
  end

  test "omits the system message when no system_prompt is given" do
    {:ok, %Aikido.Types.ActionResult{changes: changes, directives: [_]}} =
      then(ask_signal(%{system_prompt: nil}), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, idle_slice()),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    messages = Context.to_list(changes.context)
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

    {:ok, %Aikido.Types.ActionResult{changes: changes, directives: [_]}} =
      then(ask_signal(), fn signal ->
        Aikido.AiReact.Slice
        |> Ash.ActionInput.for_action(:ask, Map.put(signal.data || %{}, :state, slice),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert changes.status == :setup
    assert changes.result == nil
    assert changes.error == nil
    assert changes.previous_tool_signature == nil
    assert changes.pending_tool_calls == []
    assert changes.tool_results_received == []
  end

  test "rejects a concurrent ask while the slice is :running" do
    slice = %{idle_slice() | status: :running, request_id: "req_inflight"}

    assert {:error, %Ash.Error.Unknown{}} =
             then(ask_signal(), fn signal ->
               Aikido.AiReact.Slice
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
        Aikido.AiReact.Slice,
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
          Aikido.AiReact.Slice,
          :ask,
          Map.merge(ask_signal().data, %{state: idle_slice(), client: client})
        )

      assert input.valid?
      assert input.arguments.client == client

      assert %{client: ^client} =
               Aikido.Slice.Config.resolve_config!(Aikido.AiReact.Slice, %{client: client})
    end

    invalid =
      Ash.ActionInput.for_action(
        Aikido.AiReact.Slice,
        :ask,
        Map.merge(ask_signal().data, %{state: idle_slice(), client: AikidoTest.NonexistentClient})
      )

    refute invalid.valid?

    assert_raise ArgumentError, fn ->
      Aikido.Slice.Config.resolve_config!(Aikido.AiReact.Slice, %{
        client: AikidoTest.NonexistentClient
      })
    end

    worker =
      Ash.ActionInput.for_action(Aikido.AiWorker.Slice, :accept, %{
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
