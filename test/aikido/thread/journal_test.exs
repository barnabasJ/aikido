defmodule Aikido.Thread.JournalTest do
  use ExUnit.Case, async: true

  alias Aikido.Thread.{EntryReceipts, Journal, Slice}
  alias Aikido.Thread.Types.Entry

  @signal %Aikido.Signal{
    id: "journal-operation",
    type: "test.journal.append",
    time: "2026-11-25T00:00:00Z"
  }
  @later %Aikido.Signal{
    id: "journal-retry",
    type: "test.journal.append",
    time: "2026-11-25T00:01:00Z"
  }

  defp create(replay?), do: Ash.create!(Slice, %{id: "messages", replay?: replay?})

  defp adopt(before, proposed),
    do: Ash.update!(before, Journal.changes(before, proposed), action: :update)

  test "returns only the exact newly built typed entries in input order in both modes" do
    for replay? <- [false, true] do
      initial = create(replay?)
      {:ok, proposed} = Journal.append(initial, %{id: "earlier"}, @signal)
      prior = adopt(initial, proposed)

      incoming = [
        %{id: "first", kind: :message},
        %{id: "second", at: "123", refs: %{origin: "app"}}
      ]

      assert {:ok, updated, [first, second] = accepted} =
               Journal.append_with_entries(prior, incoming, @signal)

      assert Enum.all?(accepted, &is_struct(&1, Entry))
      assert Enum.map(accepted, & &1.id) == ["first", "second"]
      assert Enum.map(accepted, & &1.seq) == [1, 2]
      assert first.at == Aikido.Signal.timestamp(@signal)
      assert first.kind == :message
      assert second.at == 123
      assert second.refs == %{origin: "app"}
      assert updated.entries == prior.entries ++ accepted
      assert updated.rev == prior.rev + 2
      assert adopt(prior, updated).entries == updated.entries

      if replay? do
        assert first.refs == %{
                 signal_id: @signal.id,
                 signal_type: @signal.type,
                 signal_time: first.at
               }

        assert {:ok, known} = EntryReceipts.retained(updated)

        for entry <- accepted do
          assert {:ok, receipt} = EntryReceipts.from_entry(entry)
          assert known[entry.id] == receipt
        end
      else
        assert first.refs == %{}
        assert updated.entry_receipts == []
      end
    end
  end

  test "replay returns only new entries among old and within-batch duplicates" do
    initial = create(true)
    old = %{id: "old", payload: %{text: "old"}}
    fresh = %{id: "fresh", payload: %{text: "new"}}
    {:ok, previous, [_]} = Journal.append_with_entries(initial, old, @signal)
    previous = adopt(initial, previous)

    assert {:ok, updated, [accepted]} =
             Journal.append_with_entries(previous, [old, fresh, old, fresh], @later)

    assert accepted.id == "fresh"
    assert accepted.seq == 1
    assert accepted.at == Aikido.Signal.timestamp(@later)
    assert Enum.map(updated.entries, & &1.id) == ["old", "fresh"]
    assert updated.rev == previous.rev + 1
    assert {:ok, unchanged, []} = Journal.append_with_entries(updated, [old, fresh], @later)
    assert unchanged == updated
  end

  test "ordinary mode preserves repeated IDs without replay filtering" do
    initial = create(false)
    entry = %{id: "repeat", payload: %{text: "same"}}

    assert {:ok, updated, accepted} =
             Journal.append_with_entries(initial, [entry, entry], @signal)

    assert Enum.map(accepted, & &1.id) == ["repeat", "repeat"]
    assert Enum.map(accepted, & &1.seq) == [0, 1]
    assert updated.entries == accepted
    assert updated.entry_receipts == []
  end

  test "retained receipts suppress pruned retries and preserve the next accepted sequence" do
    initial = create(true)
    old = %{id: "pruned", payload: %{text: "keep receipt"}}
    {:ok, proposed, [_]} = Journal.append_with_entries(initial, old, @signal)
    adopted = adopt(initial, proposed)

    result =
      Slice
      |> Ash.ActionInput.for_action(:prune, %{state: adopted, path: :thread, through_sequence: 0},
        context: %{aikido: %{signal: @later, slice_path: :thread}}
      )
      |> Ash.run_action!()

    pruned = Ash.update!(adopted, result.changes, action: :update)
    assert pruned.entries == []
    assert length(pruned.entry_receipts) == 1
    assert {:ok, unchanged, []} = Journal.append_with_entries(pruned, old, @later)
    assert unchanged == pruned

    assert {:ok, _updated, [fresh]} =
             Journal.append_with_entries(pruned, [old, %{id: "next"}], @later)

    assert fresh.id == "next"
    assert fresh.seq == 1

    assert {:error, _} =
             Journal.append_with_entries(pruned, %{old | payload: %{text: "conflict"}}, @later)
  end

  test "both modes return the complete accepted batch above 1024 without a history prefix" do
    incoming = Enum.map(1..1100, &%{id: "entry-#{&1}", payload: %{index: &1}})

    for replay? <- [false, true] do
      initial = create(replay?)
      {:ok, previous} = Journal.append(initial, %{id: "retained-prefix"}, @signal)
      previous = adopt(initial, previous)
      assert {:ok, updated, accepted} = Journal.append_with_entries(previous, incoming, @later)
      assert length(accepted) == 1100
      assert Enum.map(accepted, & &1.payload.index) == Enum.to_list(1..1100)
      assert Enum.map(accepted, & &1.seq) == Enum.to_list(1..1100)
      assert updated.entries == previous.entries ++ accepted
    end
  end

  test "malformed entries reject the whole batch in either API and mode" do
    incoming = [%{id: "valid"}, %{id: "invalid", payload: "not a map"}]

    for replay? <- [false, true] do
      initial = create(replay?)
      assert {:error, reason} = Journal.append_with_entries(initial, incoming, @signal)
      assert {:error, old_reason} = Journal.append(initial, incoming, @signal)
      error = Ash.Error.to_error_class(reason)
      old_error = Ash.Error.to_error_class(old_reason)
      assert error.__struct__ == old_error.__struct__

      assert Enum.map(error.errors, &Exception.message/1) ==
               Enum.map(old_error.errors, &Exception.message/1)

      assert Enum.any?(error.errors, &(&1.field == :payload))
      assert initial.entries == []
      assert initial.rev == 0
      assert initial.entry_receipts == []
    end
  end

  test "a replay identity conflict yields no partial accepted batch and preserves old API errors" do
    initial = create(true)
    original = %{id: "same", payload: %{text: "original"}}
    {:ok, previous, [_]} = Journal.append_with_entries(initial, original, @signal)
    previous = adopt(initial, previous)
    incoming = [%{id: "valid-new"}, %{original | payload: %{text: "different"}}]

    assert {:error, error} = Journal.append_with_entries(previous, incoming, @later)
    assert {:error, old_error} = Journal.append(previous, incoming, @later)
    assert Exception.message(old_error) == Exception.message(error)
    assert Enum.map(previous.entries, & &1.id) == ["same"]
    assert length(previous.entry_receipts) == 1

    assert {:error, _} =
             Journal.append_with_entries(
               initial,
               [original, %{original | payload: %{text: "different"}}],
               @signal
             )
  end

  test "append keeps its two-tuple state contract and empty-batch semantics in both modes" do
    for replay? <- [false, true] do
      initial = create(replay?)

      for incoming <- [%{kind: :message}, [%{id: "one"}, %{id: "two"}], [], nil] do
        assert {:ok, updated, _} = Journal.append_with_entries(initial, incoming, @signal)
        assert {:ok, ^updated} = Journal.append(initial, incoming, @signal)
      end

      assert {:ok, empty, []} = Journal.append_with_entries(initial, [], @later)

      if replay?,
        do: assert(empty == initial),
        else: assert(empty.updated_at == Aikido.Signal.timestamp(@later))
    end
  end
end
