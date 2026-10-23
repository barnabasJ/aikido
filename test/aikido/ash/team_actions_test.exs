defmodule AikidoTest.AshTeamActionsTest do
  use ExUnit.Case, async: true

  alias AikidoTest.AshFixtures.DynamicTeam

  test "replaying a queued command preserves its exact scope instead of inheriting the preceding caller" do
    queued =
      Aikido.Signal.new!("aikido.ash.team.add_member", %{member: "next"})
      |> Aikido.Signal.put_ctx(%{actor: nil, context: %{request: "next"}})

    previous =
      Aikido.Signal.new!("aikido.ash.team.operation.completed", %{})
      |> Aikido.Signal.put_ctx(%{actor: %{id: "other"}, tenant: "other-tenant"})

    state = %{queued_operations: [queued]}

    assert {%{queued_operations: []}, [effect]} =
             Aikido.Team.TopologyOperation.release_queued_operations(state, %{agent_pid: self()})

    assert :ok = Aikido.Directives.Emit.exec(effect, previous, %{})
    assert_received {:signal, replayed}
    assert replayed == queued
    refute Map.has_key?(Aikido.Signal.ctx(replayed), :tenant)
  end

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
