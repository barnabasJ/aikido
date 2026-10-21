defmodule AikidoTest.Memory.Actions.MutationTest do
  use ExUnit.Case, async: true

  @signal %Aikido.Signal{type: "memory.test", time: "2026-10-21T12:00:00Z"}

  test "map and list mutations update space/container revisions and preserve unrelated state" do
    state = Ash.create!(Aikido.Memory.Slice, %{metadata: %{owner: "caller"}, created_at: 123})
    first = run!(state, :put_in_space, %{space: :world, key: :temperature, value: 22})
    assert first.spaces.world.data == %{temperature: 22}
    assert first.spaces.world.rev == 1
    assert first.rev == 1
    assert first.updated_at == Aikido.Signal.timestamp(@signal)
    assert first.created_at == 123
    assert first.metadata == %{owner: "caller"}
    assert state.spaces.world.data == %{}

    second = run!(first, :delete_from_space, %{space: :world, key: :temperature})
    assert second.spaces.world.data == %{}
    assert second.spaces.world.rev == 2
    assert second.rev == 2

    third = run!(second, :append_to_space, %{space: :tasks, item: %{text: "inspect"}})
    assert third.spaces.tasks.data == [%{text: "inspect"}]
    assert third.spaces.tasks.rev == 1
    assert third.spaces.world.rev == 2
    assert third.rev == 3
  end

  test "ensure_space preserves existing data and a repeated ensure does not bump revisions" do
    state = Ash.create!(Aikido.Memory.Slice, %{})
    created = run!(state, :ensure_space, %{space: :notes, default: []})
    assert created.spaces.notes.data == []
    assert created.rev == 1
    unchanged = run!(created, :ensure_space, %{space: :notes, default: %{overwrite: true}})
    assert unchanged == created
  end

  test "delete removes ordinary spaces but rejects reserved spaces with a native argument error" do
    state = Ash.create!(Aikido.Memory.Slice, %{})
    created = run!(state, :ensure_space, %{space: :notes})
    removed = run!(created, :delete_space, %{space: :notes})
    refute Map.has_key?(removed.spaces, :notes)
    assert removed.rev == 2

    for name <- [:world, :tasks] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               run(state, :delete_space, %{space: name})

      assert Enum.any?(errors, &match?(%Ash.Error.Action.InvalidArgument{field: :space}, &1))
    end
  end

  test "missing spaces and wrong data kinds fail without an exception or state change" do
    state = Ash.create!(Aikido.Memory.Slice, %{})

    for {action, params} <- [
          {:put_in_space, %{space: :missing, key: :x, value: 1}},
          {:update_space, %{space: :missing, value: %{data: %{}}}},
          {:delete_from_space, %{space: :tasks, key: :x}},
          {:append_to_space, %{space: :world, item: 1}}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = run(state, action, params)
      assert Enum.any?(errors, &match?(%Ash.Error.Action.InvalidArgument{field: :space}, &1))
    end

    assert state.rev == 0
  end

  defp run(state, action, params) do
    Aikido.Memory.Slice
    |> Ash.ActionInput.for_action(action, Map.put(params, :state, state),
      context: %{aikido: %{signal: @signal}}
    )
    |> Ash.run_action()
  end

  defp run!(state, action, params) do
    {:ok, result} = run(state, action, params)
    assert result.directives == []
    result.state
  end
end
