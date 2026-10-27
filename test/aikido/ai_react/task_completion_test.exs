defmodule Aikido.AiReact.TaskCompletionTest do
  use AikidoTest.Case, async: true
  alias Aikido.AiReact.RunState

  test "a proposed answer waits for its team's results and resumes the same scoped run" do
    state =
      AikidoTest.SliceState.new(Aikido.AiReact.Slice, %{
        status: :running,
        model: "offline",
        request_id: "original",
        deadline_at: 9_999_999_999_999,
        iteration: 4,
        context: ReqLLM.Context.new([ReqLLM.Context.user("question")]),
        prepared_tools: {[], %{}},
        options: Aikido.AiReact.Options.new!(completion: :tasks),
        run_scope: %{actor: %{id: "caller"}, tenant: "workspace"}
      })

    task = %{status: :dispatched, mode: :background, requester: :self, notify: :self}
    team = %{tasks: %{"child" => task}, pending_tasks: %{}}
    input = %{arguments: %{state: state}, context: %{aikido: %{agent: %{state: %{team: team}}}}}
    proposed = %{state | status: :completed, result: "Waiting for evidence"}

    assert {:ok, %{state: waiting, directives: []}} =
             RunState.resolve_run_outcome(Aikido.Types.ActionResult.new(state: proposed), input)

    assert waiting.status == :waiting
    assert waiting.prepared_tools == state.prepared_tools

    assert {:error, _} = deliver(waiting, %{id: "other"})
    assert {:ok, %{state: resumed, directives: [request]}} = deliver(waiting, %{id: "caller"})
    assert resumed.status == :running
    assert resumed.request_id == state.request_id
    assert resumed.deadline_at == state.deadline_at
    assert resumed.iteration == 4
    assert request.iteration == 5
    assert request.deadline_at == state.deadline_at
    assert request.request_id == state.request_id
    assert resumed.run_scope == state.run_scope
    assert resumed.run_metadata.deliveries == [%{request_id: "result/child", metadata: %{}}]
    assert List.last(resumed.context.messages).content |> hd() |> Map.fetch!(:text) == "evidence"

    settled = put_in(input.context.aikido.agent.state.team.tasks["child"].status, :completed)

    assert {:ok, %{state: completed}} =
             RunState.resolve_run_outcome(Aikido.Types.ActionResult.new(state: proposed), settled)

    assert completed.status == :completed
    assert completed.prepared_tools == nil
  end

  test "fire-and-forget work and other requesters do not hold the team's answer" do
    state = %{status: :completed, error: nil}

    for task <- [
          %{status: :completed, mode: :background, requester: :self, notify: :self},
          %{status: :failed, mode: :background, requester: :self, notify: :self},
          %{status: :dispatched, mode: :background, requester: :self, notify: nil},
          %{status: :dispatched, mode: :background, requester: :member, notify: :member}
        ] do
      team = %{tasks: %{"task" => task}, pending_tasks: %{}}
      assert Aikido.Team.TaskCompletion.await_background_results(state, %{team: team}) == state
    end
  end

  defp deliver(state, actor) do
    Aikido.AiReact.Slice
    |> Ash.ActionInput.for_action(
      :deliver,
      %{
        state: state,
        text: "evidence",
        request_id: "result/child",
        metadata: %{}
      },
      context: %{aikido: %{actor: actor, tenant: "workspace"}}
    )
    |> Ash.run_action()
  end
end
