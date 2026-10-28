defmodule AikidoTest.Thread.Actions.AppendTest do
  use ExUnit.Case, async: true

  @signal %Aikido.Signal{type: "aikido.thread.append", time: "2026-10-21T12:00:00Z"}

  test "native creation supplies thread defaults without a separate constructor" do
    state = Ash.create!(Aikido.Thread.Slice, %{})
    assert state.id == "thread"
    assert state.entries == []
    assert state.rev == 0
    assert state.stats == %{entry_count: 0}
  end

  test "append creates typed entries with deterministic IDs and input timestamps" do
    state = Ash.create!(Aikido.Thread.Slice, %{id: "conversation", metadata: %{owner: "caller"}})
    assert {:ok, result} = append(state, %{payload: %{text: "hello"}})
    [entry] = result.changes.entries
    assert %Aikido.Thread.Types.Entry{} = entry
    assert entry.id == "conversation:0:0"
    assert entry.at == Aikido.Signal.timestamp(@signal)
    assert entry.seq == 0
    assert entry.kind == :note
    assert entry.payload == %{text: "hello"}
    assert entry.refs == %{}
    refute Map.has_key?(result.changes, :metadata)
    updated = Ash.update!(state, result.changes, action: :update)
    assert updated.metadata == state.metadata
    assert updated.id == state.id
    assert result.changes.updated_at == entry.at
    assert result.changes.rev == 1
    assert result.changes.stats.entry_count == 1
    assert result.directives == []
    assert state.entries == []
  end

  test "batched and subsequent appends preserve order and advance sequences and revisions" do
    state = Ash.create!(Aikido.Thread.Slice, %{})
    assert {:ok, first} = append(state, [%{kind: :message}, %{kind: :tool_call}])
    adopted = Ash.update!(state, first.changes, action: :update)
    assert {:ok, second} = append(adopted, %{kind: :tool_result, seq: 999})
    assert Enum.map(second.changes.entries, & &1.seq) == [0, 1, 2]
    assert Enum.map(second.changes.entries, & &1.kind) == [:message, :tool_call, :tool_result]
    assert second.changes.rev == 3
    assert second.changes.stats.entry_count == 3
  end

  test "native casting accepts string keys and preserves supplied entry identity and time" do
    state = Ash.create!(Aikido.Thread.Slice, %{})

    assert {:ok, result} =
             append(state, %{
               "id" => "supplied",
               "at" => "123",
               "kind" => "message",
               "payload" => %{"text" => "hello"},
               "refs" => %{"source" => "caller"}
             })

    [entry] = result.changes.entries
    assert entry.id == "supplied"
    assert entry.at == 123
    assert entry.kind == :message
    assert entry.refs == %{"source" => "caller"}
  end

  test "invalid entries reject the complete batch without changing the original state" do
    state = Ash.create!(Aikido.Thread.Slice, %{})
    assert {:error, _} = append(state, [%{kind: :message}, %{payload: "invalid"}])
    assert state.entries == []
    assert state.rev == 0
  end

  test "explicit nil values follow the entry type's non-null constraints" do
    state = Ash.create!(Aikido.Thread.Slice, %{})
    assert {:error, _} = append(state, %{kind: nil})
  end

  defp append(state, entry) do
    Aikido.Thread.Slice
    |> Ash.ActionInput.for_action(:append, %{state: state, entry: entry},
      context: %{aikido: %{signal: @signal}}
    )
    |> Ash.run_action()
  end
end
