defmodule AikidoTest.AshTeamTopologyTest do
  use ExUnit.Case, async: true
  alias Aikido.Ash.Team.Topology
  alias AikidoTest.AshFixtures.{Counter, Instance}

  defp member_spec(options \\ []), do: Map.new([resource: Counter] ++ options)

  test "ownership and dependencies determine activation and cascading removal" do
    definition = %{
      :lead => member_spec(),
      "child" => member_spec(owner: :lead),
      :reviewer => member_spec(depends_on: ["child"])
    }

    assert {:ok, topology} = Topology.build(definition, Instance)

    assert {:ok, [:lead, "child", :reviewer]} =
             Topology.order(topology.nodes, Map.keys(topology.nodes))

    assert MapSet.new(Topology.targets(topology, [:reviewer])) ==
             MapSet.new([:lead, "child", :reviewer])

    assert {:error, {:required_by, [:reviewer]}} = Topology.remove(topology, :lead, false)
    assert {:ok, next, removed} = Topology.remove(topology, :lead, true)
    assert next.nodes == %{}
    assert next.version == topology.version + 1
    assert MapSet.new(removed) == MapSet.new([:lead, "child", :reviewer])
    assert Map.has_key?(topology.nodes, :lead)
  end

  test "unknown references, self references, and mixed ownership/dependency cycles fail" do
    for nodes <- [
          %{one: member_spec(owner: :missing)},
          %{one: member_spec(depends_on: [:missing])},
          %{one: member_spec(owner: :one)},
          %{one: member_spec(depends_on: [:one])},
          %{one: member_spec(owner: :two), two: member_spec(owner: :one)},
          %{one: member_spec(depends_on: [:two]), two: member_spec(depends_on: [:one])},
          %{one: member_spec(owner: :two), two: member_spec(depends_on: [:one])}
        ] do
      assert {:error, _} = Topology.build(nodes, Instance)
    end
  end

  test "dynamic names are unambiguous, bounded, and immutable" do
    assert {:error, :ambiguous_member_ids} =
             Topology.build(%{:one => member_spec(), "one" => member_spec()}, Instance)

    assert {:error, :member_limit} =
             Topology.build(%{one: member_spec(), two: member_spec()}, Instance, 1)

    assert {:ok, topology} = Topology.build(%{one: member_spec()}, Instance)

    assert {:error, {:member_exists, :one}} =
             Topology.put(topology, :one, member_spec(), Instance, 2)

    assert {:ok, next} = Topology.put(topology, "two", member_spec(owner: :one), Instance, 2)
    assert next.version == topology.version + 1
    assert Map.keys(topology.nodes) == [:one]
  end
end
