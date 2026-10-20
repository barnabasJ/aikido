defmodule Aikido.Ash.Team.Topology do
  @moduledoc """
  Pure, resource-based team topology. Member keys may be atoms or strings;
  dynamic names never create atoms. Ownership controls lifecycle ancestry,
  while dependencies determine activation and reverse shutdown order.
  """
  use Ash.TypedStruct

  typed_struct do
    field :nodes, :map, allow_nil?: false, default: %{}
    field :version, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
  end

  def build(definition, instance, limit \\ 128)

  def build(definition, instance, limit) when is_map(definition) do
    nodes = Map.get(definition, :nodes, definition)

    with true <- is_map(nodes) || {:error, :invalid_topology},
         true <- map_size(nodes) <= limit || {:error, :member_limit},
         {:ok, nodes} <- normalize(nodes, instance),
         true <-
           length(Enum.uniq(Enum.map(Map.keys(nodes), &to_string/1))) == map_size(nodes) ||
             {:error, :ambiguous_member_ids},
         {:ok, _} <- order(nodes, Map.keys(nodes)) do
      {:ok, %__MODULE__{nodes: nodes}}
    end
  end

  def build(_, _, _), do: {:error, :invalid_topology}

  def put(%__MODULE__{} = topology, name, spec, instance, limit) do
    if Map.has_key?(topology.nodes, name) do
      {:error, {:member_exists, name}}
    else
      with {:ok, next} <- build(Map.put(topology.nodes, name, spec), instance, limit) do
        {:ok, %{next | version: topology.version + 1}}
      end
    end
  end

  def remove(%__MODULE__{} = topology, name, cascade?) do
    with true <- Map.has_key?(topology.nodes, name) || {:error, {:unknown_member, name}} do
      owned = closure(topology.nodes, [name], :owner)
      affected = closure(topology.nodes, owned, :all)

      if !cascade? and MapSet.new(affected) != MapSet.new(owned) do
        {:error, {:required_by, affected -- owned}}
      else
        removed = if cascade?, do: affected, else: owned

        {:ok,
         %{topology | nodes: Map.drop(topology.nodes, removed), version: topology.version + 1},
         removed}
      end
    end
  end

  def targets(%__MODULE__{nodes: nodes}, requested) do
    expand_prerequisites(nodes, requested, %{}) |> Map.keys()
  end

  def eager(%__MODULE__{nodes: nodes}) do
    for {name, %{activation: :eager}} <- nodes, do: name
  end

  def affected(%__MODULE__{nodes: nodes}, names), do: closure(nodes, names, :all)

  def order(nodes, selected) do
    selected = MapSet.new(selected)
    do_order(nodes, selected, MapSet.new(), [])
  end

  defp do_order(nodes, remaining, done, result) do
    if MapSet.size(remaining) == 0 do
      {:ok, Enum.reverse(result)}
    else
      ready =
        remaining
        |> Enum.filter(fn name ->
          Enum.all?(
            prerequisites(nodes[name]),
            &(!MapSet.member?(remaining, &1) || MapSet.member?(done, &1))
          )
        end)
        |> Enum.sort()

      case ready do
        [] ->
          {:error, :cyclic_topology}

        _ ->
          do_order(
            nodes,
            Enum.reduce(ready, remaining, &MapSet.delete(&2, &1)),
            Enum.reduce(ready, done, &MapSet.put(&2, &1)),
            Enum.reverse(ready) ++ result
          )
      end
    end
  end

  defp normalize(nodes, instance) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn {name, raw}, {:ok, acc} ->
      with true <- valid_name?(name) || {:error, {:invalid_member_name, name}},
           true <- is_map(raw) || {:error, {:invalid_member, name}},
           resource when is_atom(resource) and not is_nil(resource) <- raw[:resource],
           true <-
             Code.ensure_loaded?(resource) && Spark.Dsl.is?(resource, Ash.Resource) &&
               Aikido.Ash.Agent in Spark.extensions(resource),
           true <- Aikido.Dsl.Agent.Info.agent_instance!(resource) == instance,
           activation when activation in [:eager, :lazy] <- Map.get(raw, :activation, :eager),
           dependencies when is_list(dependencies) <- Map.get(raw, :depends_on, []),
           owner <- Map.get(raw, :owner),
           true <- Enum.all?(dependencies ++ List.wrap(owner), &Map.has_key?(nodes, &1)),
           initial when is_map(initial) <- Map.get(raw, :initial_state, %{}) do
        spec = %{
          resource: resource,
          activation: activation,
          depends_on: Enum.uniq(dependencies),
          owner: owner,
          initial_state: initial,
          template: Map.get(raw, :template)
        }

        {:cont, {:ok, Map.put(acc, name, spec)}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, {:invalid_member, name}}}
      end
    end)
  end

  defp valid_name?(name) when is_atom(name), do: name not in [nil, true, false]

  defp valid_name?(name) when is_binary(name),
    do: Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/, name)

  defp valid_name?(_), do: false

  defp prerequisites(spec), do: Enum.uniq(spec.depends_on ++ List.wrap(spec.owner))

  @spec expand_prerequisites(map(), list(), map()) :: map()
  defp expand_prerequisites(nodes, [name | rest], seen) do
    if Map.has_key?(seen, name) or !Map.has_key?(nodes, name),
      do: expand_prerequisites(nodes, rest, seen),
      else:
        expand_prerequisites(nodes, prerequisites(nodes[name]) ++ rest, Map.put(seen, name, true))
  end

  defp expand_prerequisites(_nodes, [], seen), do: seen

  defp closure(nodes, seeds, field) do
    next =
      for {name, spec} <- nodes,
          Enum.any?(
            if(field == :all, do: prerequisites(spec), else: List.wrap(spec[field])),
            &(&1 in seeds)
          ),
          do: name

    expanded = Enum.uniq(seeds ++ next)
    if length(expanded) == length(seeds), do: expanded, else: closure(nodes, expanded, field)
  end
end
