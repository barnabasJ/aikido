defmodule AgentExamplesWeb.TeamTreeLayoutTest do
  use ExUnit.Case, async: true
  alias AgentExamplesWeb.TeamTreeLayout

  defp snapshot(name, members \\ [], children \\ %{}) do
    %{
      id: name,
      resource: AgentExamples.Team,
      team?: members != [],
      activity: nil,
      own: %{},
      members: members,
      children: children
    }
  end

  defp member(name, owner \\ nil), do: %{name: name, owner: owner, dynamic: true, alive: true}

  test "owner edges and nested teams share one graph without duplicate agents" do
    nested = snapshot("squad", [member("reviewer")], %{"reviewer" => snapshot("reviewer")})

    root =
      snapshot("root", [member("analyst"), member("helper", "analyst"), member("squad")], %{
        "analyst" => snapshot("analyst"),
        "helper" => snapshot("helper"),
        "squad" => nested
      })

    nodes = TeamTreeLayout.nodes(root, "Orchestrator")
    assert nodes[~s(["helper"])].parent == ~s(["analyst"])
    assert nodes[~s(["squad","reviewer"])].parent == ~s(["squad"])
    diagram = TeamTreeLayout.diagram(nodes, "[]")
    assert diagram.total == 5
    assert length(diagram.edges) == 4
    assert Enum.all?(diagram.nodes, &(&1.x >= 90 && &1.x <= 870))
    branch = TeamTreeLayout.diagram(nodes, ~s(["analyst"]))
    assert Enum.sort(Enum.map(branch.nodes, & &1.name)) == ["analyst", "helper"]
  end

  test "large teams have a bounded diagram while every agent remains addressable" do
    members = Enum.map(1..200, &member("worker-#{&1}"))
    children = Map.new(members, &{&1.name, snapshot(&1.name)})
    nodes = TeamTreeLayout.nodes(snapshot("root", members, children), "Team")
    diagram = TeamTreeLayout.diagram(nodes, "[]")
    assert diagram.total == 201
    assert length(diagram.nodes) == 80
    assert length(diagram.edges) == 79
    assert Enum.all?(diagram.nodes, &(&1.x >= 90 && &1.x <= 870))

    assert [%{name: "worker-200", x: 480}] =
             TeamTreeLayout.diagram(nodes, ~s(["worker-200"])).nodes
  end
end
