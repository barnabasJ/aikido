defmodule AgentExamples.Quicksort.TreeView do
  @moduledoc "Incremental partition counts and bounded subtree presentation, independent of the total tree size."

  @doc "Creates an empty view of a sorting tree."
  def new, do: %{nodes: %{}, completed: 0, failed: 0, levels: %{}}

  @doc "Rebuilds counters once from a retained tree after reconnecting."
  def from_nodes(nodes),
    do: Enum.reduce(nodes, new(), fn {_, node}, tree -> put_node(tree, node) end)

  @doc "Adopts a new node or a later status without letting delayed events regress its status."
  def put_node(tree, node) do
    prior = tree.nodes[node.branch]

    cond do
      prior && prior.status in [:completed, :failed] ->
        tree

      prior && prior.status == :sorting && node.status == :idle ->
        tree

      true ->
        levels =
          if prior,
            do: tree.levels,
            else: Map.update(tree.levels, String.length(node.branch) - 4, 1, &(&1 + 1))

        completed = tree.completed + if(node.status == :completed, do: 1, else: 0)
        failed = tree.failed + if(node.status == :failed, do: 1, else: 0)

        %{
          tree
          | nodes: Map.put(tree.nodes, node.branch, node),
            levels: levels,
            completed: completed,
            failed: failed
        }
    end
  end

  @doc "Returns cached counts and visits only the visible subtree instead of scanning every node."
  def summarize(tree, focus) do
    %{
      completed: tree.completed,
      failed: tree.failed,
      levels: Enum.sort(tree.levels),
      visible: visible_nodes(tree.nodes, :queue.from_list([focus]), [], 80),
      diagram: diagram_nodes(tree.nodes, focus, focus, 0)
    }
  end

  defp visible_nodes(_nodes, _queue, found, 0), do: Enum.reverse(found)

  defp visible_nodes(nodes, queue, found, remaining) do
    case :queue.out(queue) do
      {:empty, _} ->
        Enum.reverse(found)

      {{:value, branch}, queue} ->
        case nodes[branch] do
          nil ->
            visible_nodes(nodes, queue, found, remaining)

          node ->
            queue = :queue.in(branch <> "R", :queue.in(branch <> "L", queue))
            visible_nodes(nodes, queue, [node | found], remaining - 1)
        end
    end
  end

  defp diagram_nodes(_nodes, _focus, _branch, depth) when depth > 6, do: []

  defp diagram_nodes(nodes, focus, branch, depth) do
    case nodes[branch] do
      nil ->
        []

      node ->
        relative = String.replace_prefix(branch, focus, "")

        {left, width} =
          relative
          |> String.graphemes()
          |> Enum.reduce({0.0, 960.0}, fn direction, {left, width} ->
            {if(direction == "R", do: left + width / 2, else: left), width / 2}
          end)

        [
          Map.merge(node, %{x: left + width / 2, y: 24 + depth * 42})
          | diagram_nodes(nodes, focus, branch <> "L", depth + 1) ++
              diagram_nodes(nodes, focus, branch <> "R", depth + 1)
        ]
    end
  end
end
