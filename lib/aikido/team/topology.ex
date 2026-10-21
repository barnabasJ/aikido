defmodule Aikido.Team.Topology do
  @moduledoc """
  Pure, resource-based team topology. Member keys may be atoms or strings;
  dynamic names never create atoms. Ownership controls lifecycle ancestry,
  while dependencies determine activation and reverse shutdown order.
  """
  use Ash.TypedStruct

  typed_struct do
    field :nodes, :map do
      description "Member definitions indexed by name, including resources, ownership and activation dependencies."
      allow_nil? false
      default %{}
    end

    field :version, :integer do
      description "Topology revision incremented when the desired member graph changes."
      allow_nil? false
      default 1
      constraints min: 1
    end
  end

  def build(definition, instance, limit \\ 128)

  def build(nodes, instance, limit) when is_map(nodes) do
    with :ok <- validate_member_limit(nodes, limit),
         {:ok, nodes} <- normalize_members(nodes, instance),
         :ok <- validate_distinct_member_ids(nodes),
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
    with true <- Map.has_key?(topology.nodes, name) || {:error, {:unknown_member, name}},
         {:ok, removed} <- members_to_remove(topology, name, cascade?) do
      {:ok, %{topology | nodes: Map.drop(topology.nodes, removed), version: topology.version + 1},
       removed}
    end
  end

  def members_with_prerequisites(%__MODULE__{nodes: nodes}, requested) do
    expand_prerequisites(nodes, requested, %{}) |> Map.keys()
  end

  def eager(%__MODULE__{nodes: nodes}) do
    for {name, %{activation: :eager}} <- nodes, do: name
  end

  def members_with_dependents(%__MODULE__{nodes: nodes}, names),
    do: expand_dependents(nodes, names, :all)

  @doc "Returns the supplied members and their ownership descendants, excluding dependents."
  def owned_members(%__MODULE__{nodes: nodes}, names), do: expand_dependents(nodes, names, :owner)

  def order(nodes, selected) do
    selected = MapSet.new(selected)
    order_ready_members(nodes, selected, [])
  end

  defp order_ready_members(nodes, remaining, result) do
    if MapSet.size(remaining) == 0 do
      {:ok, Enum.reverse(result)}
    else
      ready = members_with_satisfied_prerequisites(nodes, remaining)

      case ready do
        [] ->
          {:error, :cyclic_topology}

        _ ->
          order_ready_members(
            nodes,
            Enum.reduce(ready, remaining, &MapSet.delete(&2, &1)),
            Enum.reverse(ready) ++ result
          )
      end
    end
  end

  defp members_with_satisfied_prerequisites(nodes, remaining) do
    remaining
    |> Enum.filter(fn name ->
      Enum.all?(prerequisites(nodes[name]), &(!MapSet.member?(remaining, &1)))
    end)
    |> Enum.sort()
  end

  defp validate_member_limit(nodes, limit) do
    if map_size(nodes) <= limit, do: :ok, else: {:error, :member_limit}
  end

  defp validate_distinct_member_ids(nodes) do
    ids = nodes |> Map.keys() |> Enum.map(&to_string/1) |> Enum.uniq()
    if length(ids) == map_size(nodes), do: :ok, else: {:error, :ambiguous_member_ids}
  end

  defp members_to_remove(topology, name, cascade?) do
    owned = owned_members(topology, [name])
    affected = expand_dependents(topology.nodes, owned, :all)

    if !cascade? and MapSet.new(affected) != MapSet.new(owned),
      do: {:error, {:required_by, affected -- owned}},
      else: {:ok, if(cascade?, do: affected, else: owned)}
  end

  defp normalize_members(nodes, instance) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn {name, raw}, {:ok, normalized} ->
      case normalize_member(name, raw, nodes, instance) do
        {:ok, spec} -> {:cont, {:ok, Map.put(normalized, name, spec)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_member(name, raw, nodes, instance) do
    with true <- valid_name?(name) || {:error, {:invalid_member_name, name}},
         true <- is_map(raw) || {:error, {:invalid_member, name}},
         :ok <- validate_member_resource(raw[:resource], instance),
         {:ok, spec} <- member_attributes(raw),
         :ok <- validate_member_references(spec, nodes) do
      {:ok, spec}
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_member, name}}
    end
  end

  defp validate_member_resource(resource, instance) do
    if is_atom(resource) and not is_nil(resource) and Code.ensure_loaded?(resource) and
         Spark.Dsl.is?(resource, Ash.Resource) and
         Aikido.Agent.Extension in Spark.extensions(resource) and
         Aikido.Agent.Info.agent_instance!(resource) == instance,
       do: :ok,
       else: :invalid_resource
  end

  defp member_attributes(raw) do
    with activation when activation in [:eager, :lazy] <- Map.get(raw, :activation, :eager),
         dependencies when is_list(dependencies) <- Map.get(raw, :depends_on, []),
         initial when is_map(initial) <- Map.get(raw, :initial_state, %{}) do
      {:ok,
       %{
         resource: raw.resource,
         activation: activation,
         depends_on: Enum.uniq(dependencies),
         owner: Map.get(raw, :owner),
         initial_state: initial,
         template: Map.get(raw, :template)
       }}
    else
      _ -> :invalid_attributes
    end
  end

  defp validate_member_references(spec, nodes) do
    if Enum.all?(prerequisites(spec), &Map.has_key?(nodes, &1)),
      do: :ok,
      else: :invalid_references
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

  defp expand_dependents(nodes, seeds, field) do
    next =
      for {name, spec} <- nodes,
          Enum.any?(
            if(field == :all, do: prerequisites(spec), else: List.wrap(spec[field])),
            &(&1 in seeds)
          ),
          do: name

    expanded = Enum.uniq(seeds ++ next)

    if length(expanded) == length(seeds),
      do: expanded,
      else: expand_dependents(nodes, expanded, field)
  end
end
