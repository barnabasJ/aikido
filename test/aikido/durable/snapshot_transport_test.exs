defmodule Aikido.Durable.SnapshotTransportTest do
  use ExUnit.Case, async: true

  alias Aikido.Durable.Snapshot

  test "transport rejects executable values nested in compressed and uncompressed legacy snapshots" do
    for function <- [fn value -> value end, &String.length/1],
        value <- [
          function,
          [function],
          {:value, function},
          %{value: function},
          %{function => :value}
        ],
        options <- [[], [:compressed]] do
      payload = %{checkpoint: value} |> :erlang.term_to_binary(options) |> Base.encode64()

      assert_raise ArgumentError, ~r/not safe for deserialization/, fn ->
        Snapshot.load(%{"payload" => payload})
      end
    end
  end

  test "legacy transport retains inert terms, binary type representations and monitor identities" do
    value = %{
      binary: <<0, 255, 131>>,
      fields: {:ok, [1, nil, "value"]},
      pid: self(),
      ref: make_ref()
    }

    for options <- [[], [:compressed]] do
      payload = value |> :erlang.term_to_binary(options) |> Base.encode64()
      assert Snapshot.load(%{"payload" => payload}) == value
    end
  end
end
