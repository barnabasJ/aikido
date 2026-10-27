defmodule AgentExamples.Quicksort.TreeViewTest do
  use ExUnit.Case, async: true
  alias AgentExamples.Quicksort.TreeView

  test "counts nodes and completions once despite duplicate and reordered notifications" do
    root = node("root", :sorting)
    child = node("rootL", :completed)
    tree = TreeView.new() |> TreeView.put_node(root) |> TreeView.put_node(child)

    tree =
      tree
      |> TreeView.put_node(child)
      |> TreeView.put_node(node("rootL", :idle))
      |> TreeView.put_node(node("root", :idle))

    view = TreeView.summarize(tree, "root")
    assert view.completed == 1
    assert view.levels == [{0, 1}, {1, 1}]
    assert Enum.map(view.visible, & &1.branch) == ["root", "rootL"]
    assert tree.nodes["root"].status == :sorting
  end

  test "reconnect rebuilds the same summary and visible traversal remains bounded" do
    nodes =
      Map.new(1..4096, fn index ->
        branch =
          "root" <>
            (index
             |> Integer.to_string(2)
             |> String.slice(1..-1//1)
             |> String.replace("0", "L")
             |> String.replace("1", "R"))

        {branch, node(branch, :completed)}
      end)

    view = nodes |> TreeView.from_nodes() |> TreeView.summarize("root")
    assert view.completed == 4096
    assert Enum.sum(Enum.map(view.levels, &elem(&1, 1))) == 4096
    assert length(view.visible) == 80
    assert length(view.diagram) == 127

    assert Enum.map(view.visible, & &1.branch) ==
             nodes |> Map.keys() |> Enum.sort_by(&{String.length(&1), &1}) |> Enum.take(80)
  end

  defp node(branch, status), do: %{branch: branch, id: branch, status: status, count: 1, pivot: 1}
end
