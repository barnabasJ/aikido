defmodule AikidoTest.AshTeamActionsTest do
  use ExUnit.Case, async: true

  alias AikidoTest.AshFixtures.DynamicTeam

  test "the native action owns its operation independently of the signal envelope type" do
    recipient = self()
    state = %{members: %{worker: recipient}}

    input =
      Ash.ActionInput.for_action(
        Aikido.Team.Slice,
        :send,
        %{state: state, member: :worker, type: "worker.notice", payload: %{value: 7}},
        context: %{
          aikido: %{
            agent_module: DynamicTeam,
            signal: %Aikido.Signal{
              id: "native-send",
              type: "unrelated.envelope",
              data: %{},
              source: "/test"
            }
          }
        }
      )

    assert {:ok,
            %Aikido.Types.ActionResult{
              state: ^state,
              directives: [
                %Aikido.Directives.Emit{
                  target: ^recipient,
                  signal: %Aikido.Signal{type: "worker.notice", data: %{value: 7}}
                }
              ]
            }} = Ash.run_action(input)

    refute_received {:signal, _}
  end
end
