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
    assert result.state.id == state.id
    assert result.state.metadata == state.metadata
    assert result.state.created_at == 123
    assert result.state.entries == []
    assert result.state.stats.entry_count == 0
    assert result.state.rev == 3
    assert result.state.updated_at == Aikido.Signal.timestamp(signal)
    assert result.directives == []
    assert length(state.entries) == 1

    assert {:ok, again} = clear(result.state, signal)
    assert again.state.rev == 4
    assert again.state.entries == []
  end

  defp clear(state, signal) do
    Aikido.Thread.Slice
    |> Ash.ActionInput.for_action(:clear, %{state: state}, context: %{aikido: %{signal: signal}})
    |> Ash.run_action()
  end
end
