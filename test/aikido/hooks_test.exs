defmodule Aikido.HooksTest.Agent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "hook_test"
    slice :ai, Aikido.Slices.AiReact
  end
end

defmodule Aikido.HooksTest.Client do
  @moduledoc false
  @behaviour Aikido.AI.Client

  def generate_text(model, messages, _opts) do
    if model == "tools" && not Enum.any?(messages, &(&1.role == :tool)) do
      {:ok,
       struct!(ReqLLM.Response,
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message:
           ReqLLM.Context.assistant("",
             tool_calls: [
               %{id: "sum", name: "test_add", arguments: %{"input" => %{"a" => 2, "b" => 3}}}
             ]
           ),
         finish_reason: :tool_calls
       )}
    else
      text = messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", &(&1.text || ""))

      {:ok,
       struct!(ReqLLM.Response,
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant(text, tool_calls: []),
         finish_reason: :stop
       )}
    end
  end
end

defmodule Aikido.HooksTest do
  use AikidoTest.Case, async: true
  alias Aikido.Hooks.{Hook, Decision, Execute}
  alias Aikido.Slices.AiReact.Directives.LLMCall

  defp hook(script, options \\ []) do
    {:ok, hook} =
      Ash.Type.cast_input(
        Hook,
        Map.new([name: "test", event: :before_model, script: script] ++ options)
      )

    hook
  end

  defp state(hooks) do
    %{
      status: :running,
      request_id: "run",
      iteration: 0,
      context: ReqLLM.Context.new([ReqLLM.Context.user("hello")]),
      hooks: hooks,
      result: nil
    }
  end

  defp complete(state, effect, result) do
    Aikido.Hooks.completed(state, %{
      token: effect.token,
      request_id: effect.request_id,
      name: effect.hook.name,
      mode: effect.hook.mode,
      result: result
    })
  end

  test "native Ash contracts reject unsupported events and modes" do
    assert {:error, _} =
             Ash.Type.cast_input(Hook, %{name: "bad", event: "unknown", script: "return nil"})

    assert {:error, _} =
             Ash.Type.cast_input(Hook, %{
               name: "bad",
               event: :before_model,
               mode: "unknown",
               script: "return nil"
             })
  end

  test "Lua returns typed decisions and uses the event snapshot" do
    h = hook(~s(return {context = event.request_id, decision = "continue"}))

    assert {:ok, %Decision{context: "run", decision: :continue}} =
             Execute.evaluate(h, %{request_id: "run"}, self(), "run")

    assert {:ok, %Decision{decision: :continue}} =
             Execute.evaluate(hook("return nil"), %{}, self(), "run")

    assert {:error, _} =
             Execute.evaluate(hook(~s(return {decision = "whatever"})), %{}, self(), "run")
  end

  test "runaway scripts stop at native instruction limits and sync hooks cannot emit" do
    assert {:error, _} =
             Execute.evaluate(
               hook("while true do end", max_instructions: 100),
               %{},
               self(),
               "run"
             )

    assert {:error, _} = Execute.evaluate(hook(~s|aikido.send_context("no")|), %{}, self(), "run")
    assert {:error, _} = Execute.evaluate(hook(~s|os.execute("anything")|), %{}, self(), "run")
  end

  test "sync gates release the model only after ordered decisions, with updated context" do
    hooks = [
      hook(~s(return {context = "first"})),
      hook(~s(return {context = "second"}), name: "second")
    ]

    state = state(hooks)
    model = %LLMCall{model: "offline", request_id: "run", context: state.context}
    {:ok, result} = Aikido.Types.ActionResult.new(state: state, directives: [model])

    {:ok, %{state: waiting, directives: [gate]}} =
      Aikido.Hooks.transition({:ok, result}, :run_started, %{})

    assert %Execute{} = gate

    {:ok, %{state: waiting, directives: [second]}} =
      complete(waiting, gate, Execute.evaluate(gate.hook, gate.event, self(), "run"))

    assert %Execute{} = second

    {:ok, %{state: ready, directives: [%LLMCall{} = released]}} =
      complete(waiting, second, Execute.evaluate(second.hook, second.event, self(), "run"))

    assert ready.hooks_pending == %{}
    assert ready.hook_context == []
    assert released.context == ready.context

    text =
      released.context
      |> ReqLLM.Context.to_list()
      |> Enum.flat_map(& &1.content)
      |> Enum.map_join("\n", & &1.text)

    assert text =~ "first"
    assert text =~ "second"

    {:ok, %{state: unchanged, directives: []}} =
      complete(ready, second, {:ok, %Decision{decision: :continue}})

    assert unchanged == ready
  end

  test "denial and failures do not release held effects" do
    for response <- [{:ok, %Decision{decision: :deny, message: "blocked"}}, {:error, "broken"}] do
      state = state([hook("return nil")])

      {:ok, result} =
        Aikido.Types.ActionResult.new(
          state: state,
          directives: [%LLMCall{model: "offline", request_id: "run", context: state.context}]
        )

      {:ok, %{state: waiting, directives: [gate]}} =
        Aikido.Hooks.transition({:ok, result}, :run_started, %{})

      {:ok, %{state: failed, directives: []}} = complete(waiting, gate, response)
      assert failed.status == :failed
      assert failed.hooks_pending == %{}
    end
  end

  test "async callbacks send scoped signals and reject internal result signals" do
    h =
      hook(~s|aikido.send_context("evidence"); aikido.send_signal("example.notice", {value = 1})|,
        mode: :async
      )

    assert {:ok, nil} = Execute.evaluate(h, %{}, self(), "run")

    assert_receive {:"$gen_cast",
                    {:signal,
                     %{
                       type: "ai.react.hook.context",
                       data: %{text: "evidence", request_id: "run"}
                     }}}

    assert_receive {:"$gen_cast",
                    {:signal, %{type: "example.notice", data: %{"value" => 1, request_id: "run"}}}}

    assert {:error, _} =
             Execute.evaluate(
               hook(~s|aikido.send_signal("ai.react.llm.completed", {})|, mode: :async),
               %{},
               self(),
               "run"
             )
  end

  test "late context and gate results cannot affect a different run" do
    state = state([])
    {:ok, %{state: unchanged}} = Aikido.Hooks.context(state, %{request_id: "older", text: "late"})
    assert unchanged == state

    {:ok, %{state: unchanged}} =
      Aikido.Hooks.completed(state, %{
        request_id: "older",
        token: 1,
        name: "old",
        mode: :sync,
        result: {:ok, %Decision{decision: :continue}}
      })

    assert unchanged == state
  end

  test "runtime hooks supply context and complete through the existing AI interface", ctx do
    pid = start_server(ctx, Aikido.HooksTest.Agent)

    hooks = [
      %{name: "context", event: :before_model, script: ~s(return {context = "hook evidence"})}
    ]

    assert {:ok, result} =
             Aikido.AI.ask_sync(pid, "hello",
               model: "offline",
               client: Aikido.HooksTest.Client,
               hooks: hooks,
               timeout: 5_000
             )

    assert result =~ "hook evidence"
  end

  test "cancellation invalidates gates and a duplicate completion cannot release an effect" do
    state = state([hook("return nil")])

    {:ok, result} =
      Aikido.Types.ActionResult.new(
        state: state,
        directives: [%LLMCall{model: "offline", request_id: "run", context: state.context}]
      )

    {:ok, %{state: waiting, directives: [gate]}} =
      Aikido.Hooks.transition({:ok, result}, :run_started, %{})

    signal = Jido.Signal.new!("ai.react.cancel", %{request_id: "run"})

    {:ok, %Aikido.Types.ActionResult{state: cancelled, directives: []}} =
      then(signal, fn signal ->
        Aikido.Slices.AiReact
        |> Ash.ActionInput.for_action(:cancel, Map.put(signal.data || %{}, :state, waiting),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert cancelled.status == :failed

    {:ok, %{state: unchanged, directives: []}} =
      complete(cancelled, gate, {:ok, %Decision{decision: :continue}})

    assert unchanged == cancelled
  end

  test "async observers do not hold up effects and their errors remain observable" do
    state = state([hook("error('observer failed')", mode: :async)])

    {:ok, result} =
      Aikido.Types.ActionResult.new(
        state: state,
        directives: [%LLMCall{model: "offline", request_id: "run", context: state.context}]
      )

    {:ok, %{state: ready, directives: [observer, %LLMCall{}]}} =
      Aikido.Hooks.transition({:ok, result}, :run_started, %{})

    {:ok, %{state: recorded, directives: []}} =
      complete(ready, observer, {:error, "observer failed"})

    assert recorded.status == :running
    assert [%{name: "test", reason: "observer failed"}] = recorded.hook_errors
  end

  test "before-tool denial fails the run before that tool executes", ctx do
    pid = start_server(ctx, Aikido.HooksTest.Agent)

    hooks = [
      %{
        name: "gate",
        event: :before_tool,
        script: ~s(return {decision = "deny", message = "not allowed"})
      }
    ]

    assert {:error, {:hook_denied, "gate", "not allowed"}} =
             Aikido.AI.ask_sync(pid, "hello",
               model: "tools",
               client: Aikido.HooksTest.Client,
               tools: [:test_add],
               hooks: hooks,
               timeout: 5_000
             )
  end

  test "terminal hooks finish before completion is published and ignore late model results" do
    state = state([hook("return nil", event: :run_completed)]) |> Map.put(:status, :completed)
    {:ok, result} = Aikido.Types.ActionResult.new(state: state)

    {:ok, %{state: waiting, directives: [gate]}} =
      Aikido.Hooks.transition({:ok, result}, :after_model, %{})

    assert waiting.status == :running
    assert waiting.hook_terminal == :completed

    turn =
      struct!(ReqLLM.Response,
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message: ReqLLM.Context.assistant("late", tool_calls: []),
        finish_reason: :stop
      )

    signal = Jido.Signal.new!("ai.react.llm.completed", %{request_id: "run", turn: turn})

    {:ok, %Aikido.Types.ActionResult{state: unchanged, directives: []}} =
      then(signal, fn signal ->
        Aikido.Slices.AiReact
        |> Ash.ActionInput.for_action(:llm_turn, Map.put(signal.data || %{}, :state, waiting),
          context: %{aikido: Map.put(%{}, :signal, signal)},
          skip_unknown_inputs: [:*]
        )
        |> Ash.run_action()
      end)

    assert unchanged == waiting

    {:ok, %{state: completed, directives: []}} =
      complete(waiting, gate, {:ok, %Decision{decision: :continue}})

    assert completed.status == :completed
    assert completed.hook_terminal == nil
  end

  test "async context waits for a model boundary and is consumed once" do
    state = state([hook("return nil", mode: :async, event: :after_tool)])

    {:ok, %{state: queued}} =
      Aikido.Hooks.context(state, %{request_id: "run", text: "later evidence", name: "observer"})

    assert queued.context == state.context
    assert [%{text: "later evidence"}] = queued.hook_context

    {:ok, result} =
      Aikido.Types.ActionResult.new(
        state: queued,
        directives: [%LLMCall{model: "offline", request_id: "run", context: state.context}]
      )

    {:ok, %{state: ready, directives: [%LLMCall{} = call]}} =
      Aikido.Hooks.transition({:ok, result}, :run_started, %{})

    assert ready.hook_context == []

    text =
      call.context
      |> ReqLLM.Context.to_list()
      |> List.last()
      |> Map.fetch!(:content)
      |> hd()
      |> Map.fetch!(:text)

    assert text == """
           [Hook context: observer]
           later evidence\
           """
  end
end
