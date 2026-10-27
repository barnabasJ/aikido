defmodule AgentExamples.NativeEvidenceTest do
  use ExUnit.Case, async: false
  alias AgentExamples.VerifiedTeam

  test "an ordinary evidence tool cannot complete a requirement without a recorded worker result" do
    actor = %{id: "example-agent"}
    scope = [actor: actor, tenant: "playground"]

    team =
      VerifiedTeam
      |> Ash.ActionInput.for_action(:start, AgentExamples.AI.offline(), scope)
      |> Ash.run_action!()

    on_exit(fn ->
      VerifiedTeam
      |> Ash.ActionInput.for_action(:stop, %{agent: team}, scope)
      |> Ash.run_action()
    end)

    VerifiedTeam
    |> Ash.ActionInput.for_action(:todo_add,
      %{agent: team, id: "required-check", text: "Evidence must be checked", blocking?: true}, scope)
    |> Ash.run_action!()

    context = %{aikido: %{agent_resource: VerifiedTeam, agent_id: team.id, parent: nil}}

    assert {:error, error} =
             AgentExamples.VerifiedTeam.Tools
             |> Ash.ActionInput.for_action(:complete_evidence, %{task_id: "required-check"},
               scope ++ [context: context])
             |> Ash.run_action()

    assert Exception.message(error) =~ "No completed required evidence assignment"

    current =
      VerifiedTeam
      |> Ash.ActionInput.for_action(:inspect, %{agent: team}, scope)
      |> Ash.run_action!()

    assert [%{id: "required-check", status: :pending, result: nil}] = current.todos.items
  end
end
