defmodule AikidoTest.Identity.Actions.UpdateProfileTest do
  use ExUnit.Case, async: true

  test "profile updates merge existing facts and advance only revision and update time" do
    state =
      Ash.create!(Aikido.Identity.Slice, %{profile: %{age: 5, origin: "lab"}, created_at: 123})

    signal = %Aikido.Signal{type: "aikido.identity.update_profile", time: "2026-10-21T12:00:00Z"}

    result =
      Aikido.Identity.Slice
      |> Ash.ActionInput.for_action(:update_profile, %{state: state, profile: %{name: "Sam"}},
        context: %{aikido: %{signal: signal}}
      )
      |> Ash.run_action!()

    assert result.state.profile == %{age: 5, origin: "lab", name: "Sam"}
    assert result.state.rev == 1
    assert result.state.created_at == 123
    assert result.state.updated_at == Aikido.Signal.timestamp(signal)
    assert result.directives == []
    assert state.profile == %{age: 5, origin: "lab"}
  end

  test "native creation accepts profile attributes and applies resource defaults" do
    state = Ash.create!(Aikido.Identity.Slice, %{profile: %{age: 0}})
    assert state.profile == %{age: 0}
    assert state.rev == 0
    assert state.created_at == 0
    assert state.updated_at == 0
  end
end
