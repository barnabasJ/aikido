defmodule AikidoTest.Types.EnumContractsTest do
  use ExUnit.Case, async: true

  alias Aikido.Slices.AiReact
  alias Aikido.Slices.AiReact.Types.Status

  test "ReAct creation casts known lifecycle stages and rejects unknown states" do
    for status <- [:idle, :setup, :running, :waiting, :completed, :failed] do
      record =
        AiReact
        |> Ash.Changeset.for_create(:create, %{status: Atom.to_string(status)})
        |> Ash.create!()

      assert record.status == status
    end

    changeset = Ash.Changeset.for_create(AiReact, :create, %{status: :unknown})
    refute changeset.valid?
    assert Enum.any?(changeset.errors, &(&1.field == :status))
  end

  test "generated reducer state arguments retain the lifecycle enum contract" do
    state = AiReact |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()
    action = Ash.Resource.Info.action(AiReact, :cancel)
    argument = Enum.find(action.arguments, &(&1.name == :state))
    assert argument.constraints[:fields][:status][:type] == Status

    input =
      Ash.ActionInput.for_action(AiReact, :cancel, %{
        state: %{state | status: :unknown},
        request_id: "enum-contract"
      })

    refute input.valid?
  end

  test "persisted lifecycle values use the enum storage representation and restore atoms" do
    attribute = Ash.Resource.Info.attribute(AiReact, :status)

    assert {:ok, "waiting"} =
             Ash.Type.dump_to_native(attribute.type, :waiting, attribute.constraints)

    assert {:ok, :waiting} =
             Ash.Type.cast_stored(attribute.type, "waiting", attribute.constraints)

    assert {:ok, :running} =
             Ash.Type.cast_stored(attribute.type, :running, attribute.constraints)
  end
end
