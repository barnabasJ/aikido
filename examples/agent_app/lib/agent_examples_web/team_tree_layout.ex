defmodule AgentExamplesWeb.TeamTreeLayout do
  @moduledoc "Projects subscribed snapshots and ownership into a bounded, navigable team diagram."

  def nodes(snapshot, root_name) do
    collect(snapshot, [], nil, root_name, nil, root_name) |> Map.new(&{&1.key, &1})
  end

  defp collect(snapshot, path, parent, name, member, root_name) do
    key = Jason.encode!(path)

    node = %{
      key: key,
      parent: parent,
      name: name,
      path: Enum.join([root_name | path], " / "),
      snapshot: snapshot,
      activity: snapshot[:activity],
      team?: snapshot[:team?] || false,
      dynamic?: member && member.dynamic,
      alive?: is_nil(member) || member.alive
    }

    children =
      Enum.flat_map(snapshot[:members] || [], fn member ->
        case snapshot.children[member.name] do
          nil ->
            []

          child ->
            owner = if member.owner, do: Jason.encode!(path ++ [member.owner]), else: key
            collect(child, path ++ [member.name], owner, member.name, member, root_name)
        end
      end)

    [node | children]
  end

  def diagram(nodes, focus) do
    children = nodes |> Map.values() |> Enum.group_by(& &1.parent)
    visible = visit(:queue.from_list([{focus, 0}]), nodes, children, [], 80)
    visible_keys = MapSet.new(visible, & &1.key)

    children =
      Map.new(children, fn {key, values} ->
        {key,
         values |> Enum.filter(&MapSet.member?(visible_keys, &1.key)) |> Enum.sort_by(& &1.name)}
      end)

    {positioned, _, _} = position(focus, 0, children, nodes, 0)
    leaves = Enum.count(positioned, &(Map.get(children, &1.key, []) == []))

    positioned =
      Enum.map(positioned, fn node ->
        %{node | x: if(leaves == 1, do: 480, else: 90 + node.x / (leaves - 1) * 780)}
      end)

    by_key = Map.new(positioned, &{&1.key, &1})
    edges = for node <- positioned, parent = by_key[node.parent], do: {parent, node}

    %{
      nodes: positioned,
      edges: edges,
      total: map_size(nodes),
      height: max(220, (Enum.max(Enum.map(visible, & &1.depth), fn -> 0 end) + 1) * 95)
    }
  end

  defp visit(_, _, _, found, 0), do: Enum.reverse(found)

  defp visit(queue, nodes, children, found, remaining) do
    case :queue.out(queue) do
      {:empty, _} ->
        Enum.reverse(found)

      {{:value, {key, depth}}, queue} ->
        node = Map.fetch!(nodes, key) |> Map.put(:depth, depth)

        queue =
          if depth < 4 do
            children
            |> Map.get(key, [])
            |> Enum.sort_by(& &1.name)
            |> Enum.reduce(queue, fn child, queue -> :queue.in({child.key, depth + 1}, queue) end)
          else
            queue
          end

        visit(queue, nodes, children, [node | found], remaining - 1)
    end
  end

  defp position(key, depth, children, nodes, next_leaf) do
    node = Map.fetch!(nodes, key)
    descendants = Map.get(children, key, [])

    {nested, centers, next_leaf} =
      Enum.reduce(descendants, {[], [], next_leaf}, fn child, {all, centers, next} ->
        {positioned, center, next} = position(child.key, depth + 1, children, nodes, next)
        {positioned ++ all, [center | centers], next}
      end)

    x = if centers == [], do: next_leaf, else: Enum.sum(centers) / length(centers)
    node = Map.merge(node, %{x: x, y: 30 + depth * 95})
    {[node | nested], x, if(centers == [], do: next_leaf + 1, else: next_leaf)}
  end
end
