defmodule Aikido.Slices.AiReact.ReplaceContextTest.Assistant do
  use Aikido.Agent, extensions: [Aikido.Ash.AI]

  agent do
    name "replace_context_test"
  end
end

defmodule Aikido.Slices.AiReact.ReplaceContextTest do
  use AikidoTest.Case, async: true
  alias Aikido.Slices.AiReact
  alias Aikido.Slices.AiReact.ReplaceContextTest.Assistant

  test "native replacement installs supplied history and refreshes its cached estimate" do
    scope = %{actor: %{id: "caller"}, tenant: "workspace"}

    state =
      AikidoTest.SliceState.new(AiReact, %{
        context: ReqLLM.Context.new([ReqLLM.Context.user("old history")]),
        estimated_tokens: 50_000,
        last_input_tokens: 25_000,
        run_scope: scope
      })

    messages = [ReqLLM.Context.user("caller-supplied summary")]

    assert %Aikido.Types.ActionResult{state: replaced, directives: []} =
             AiReact
             |> Ash.ActionInput.for_action(:replace_context, %{state: state, messages: messages})
             |> Ash.run_action!()

    assert replaced.context.messages == messages
    assert replaced.estimated_tokens == AiReact.Context.estimate_tokens(replaced.context)
    assert replaced.last_input_tokens == nil
    assert replaced.run_scope == scope
  end

  test "replacement refuses setup, running and todo-waiting conversations" do
    for status <- [:setup, :running, :waiting] do
      state = AikidoTest.SliceState.new(AiReact, %{status: status})

      assert {:error, _} =
               AiReact
               |> Ash.ActionInput.for_action(:replace_context, %{
                 state: state,
                 messages: [ReqLLM.Context.user("replacement")]
               })
               |> Ash.run_action()
    end
  end

  test "AI resources expose the replacement command with its native description", ctx do
    description =
      "Installs caller-supplied conversation history while idle and refreshes the cached token estimate."

    assert Ash.Resource.Info.action(AiReact, :replace_context).description == description
    assert Ash.Resource.Info.action(Assistant, :replace_context).description == description
    assert Ash.Resource.Info.action(Assistant, :replace_context).public?
    refute Ash.Resource.Info.action(Assistant, :handoff)
    refute Ash.Resource.Info.action(AiReact, :handoff)

    assert Aikido.Signal.Info.signal_type!(AiReact.Signals.ReplaceContext) ==
             "ai.react.replace_context"

    pid = start_server(ctx, Assistant)
    messages = [ReqLLM.Context.user("provided history")]

    assert %{status: :processed, signal_id: signal_id} =
             Assistant
             |> Ash.ActionInput.for_action(:replace_context, %{agent: pid, messages: messages},
               actor: %{id: "caller"},
               tenant: "workspace"
             )
             |> Ash.run_action!()

    assert is_binary(signal_id)

    assert {:ok, ^messages} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.context.messages})
  end
end
