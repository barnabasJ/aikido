defmodule Aikido.InitializedStateTest do
  use ExUnit.Case, async: true

  test "native ensure requires the owning state and preserves initialized values" do
    for resource <- [Aikido.Identity.Slice, Aikido.Memory.Slice, Aikido.Thread.Slice] do
      state = Ash.create!(resource, %{rev: 7, created_at: 10, updated_at: 20}, action: :create)

      input = Ash.ActionInput.for_action(resource, :ensure, %{state: state})
      validated = input.arguments.state

      assert %Aikido.Types.ActionResult{state: ^validated, directives: []} =
               Ash.run_action!(input)

      assert validated.rev == 7
      assert validated.created_at == 10
      assert validated.updated_at == 20

      for invalid <- [nil, %Aikido.Todo.Slice{}] do
        input = Ash.ActionInput.for_action(resource, :ensure, %{state: invalid})
        refute input.valid?
        assert Enum.any?(input.errors, &(&1.field == :state || :state in &1.path))
        assert {:error, %Ash.Error.Invalid{}} = Ash.run_action(input)
      end
    end
  end

  test "native thread append replay retains input-derived timestamps and entry IDs" do
    state = Ash.create!(Aikido.Thread.Slice, %{id: "thread", rev: 3}, action: :create)
    signal = %Aikido.Signal{type: "aikido.thread.append", time: "2026-10-20T12:00:00Z"}

    input =
      Ash.ActionInput.for_action(
        Aikido.Thread.Slice,
        :append,
        %{state: state, entry: [%{kind: :note}, %{kind: :message}]},
        context: %{aikido: %{signal: signal}}
      )

    first = Ash.run_action!(input)
    assert Ash.run_action!(input) == first
    assert first.directives == []
    assert Enum.map(first.state.entries, & &1.id) == ["thread:3:0", "thread:3:1"]
    assert Enum.all?(first.state.entries, &(&1.at == Aikido.Signal.timestamp(signal)))
    assert first.state.updated_at == Aikido.Signal.timestamp(signal)
  end
end
