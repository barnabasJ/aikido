defmodule AikidoTest.Thread.Actions.ClearTest do
  use ExUnit.Case, async: true

  test "clear preserves identity and metadata while advancing revision and resetting entries" do
    state =
      Ash.create!(Aikido.Thread.Slice, %{
        id: "conversation",
        metadata: %{owner: "caller"},
        created_at: 123,
        rev: 2,
        entries: [%{id: "entry", at: 123}],
        stats: %{entry_count: 1}
      })

    signal = %Aikido.Signal{type: "aikido.thread.clear", time: "2026-10-21T12:00:00Z"}
    assert {:ok, result} = clear(state, signal)
    refute Map.has_key?(result.changes, :id)
    refute Map.has_key?(result.changes, :metadata)
    refute Map.has_key?(result.changes, :created_at)
    updated = Ash.update!(state, result.changes, action: :update)
    assert updated.id == state.id
    assert updated.metadata == state.metadata
    assert updated.created_at == 123
    assert result.changes.entries == []
    assert result.changes.stats.entry_count == 0
    assert result.changes.rev == 3
    assert result.changes.updated_at == Aikido.Signal.timestamp(signal)
    assert result.directives == []
    assert length(state.entries) == 1

    assert {:ok, again} = clear(updated, signal)
    assert again.changes.rev == 4
    assert again.changes.entries == []
  end

  defp clear(state, signal) do
    Aikido.Thread.Slice
    |> Ash.ActionInput.for_action(:clear, %{state: state}, context: %{aikido: %{signal: signal}})
    |> Ash.run_action()
  end
end
