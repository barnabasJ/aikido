defmodule Aikido.Inspector.History.Redaction do
  @moduledoc "Projects sensitive fields using native Ash resource, argument and signal metadata."

  def agent_state(state, nil), do: typed_value(state)

  def agent_state(state, resource) do
    own_path = Spark.Dsl.Extension.get_opt(resource, [:agent], :path)
    mounts = Map.new(Aikido.Agent.Info.slice_instances(resource), &{&1.path, &1.module})

    Map.new(state, fn {path, value} ->
      type = if path == own_path, do: resource, else: Map.get(mounts, path)
      {path, typed_value(value, type)}
    end)
  end

  def signal_data(signal, nil), do: typed_value(signal.data)

  def signal_data(signal, resource) do
    owners = [resource | Aikido.Agent.Info.slices(resource)]

    Enum.reduce(owners, signal.data, fn owner, data ->
      section = if owner == resource, do: :agent, else: :slice

      owner
      |> Spark.Dsl.Extension.get_entities([section])
      |> Enum.filter(fn route ->
        is_binary(Map.get(route, :type)) &&
          Aikido.Signal.Router.matches_compiled?(
            signal.type,
            Aikido.Signal.Router.compile_pattern(route.type)
          )
      end)
      |> Enum.reduce(data, fn route, data ->
        if route.signal_module do
          typed_value(data, route.signal_module)
        else
          {action_resource, action_name} = Aikido.Slice.Info.action_reference(owner, route.action)

          case Ash.Resource.Info.action(action_resource, action_name) do
            %{arguments: arguments} ->
              if Enum.any?(arguments, &(&1.name == :data && &1.sensitive?)),
                do: "[redacted]",
                else: redact_fields(data, arguments, 0)

            _ ->
              data
          end
        end
      end)
    end)
  end

  def typed_value(value, type \\ nil, constraints \\ [], depth \\ 0)
  def typed_value(value, _type, _constraints, depth) when depth >= 8, do: value

  def typed_value(values, {:array, type}, constraints, depth) when is_list(values),
    do: project_list(values, type, Keyword.get(constraints, :items, []), depth)

  def typed_value(values, _type, _constraints, depth) when is_list(values),
    do: project_list(values, nil, [], depth)

  def typed_value(%Ash.Union{type: name, value: value}, _type, constraints, depth) do
    variant = Keyword.get(Keyword.get(constraints, :types, []), name, [])

    %{
      type: name,
      value: typed_value(value, variant[:type], variant[:constraints] || [], depth + 1)
    }
  end

  def typed_value(%module{} = value, _type, constraints, depth),
    do: typed_value(Map.from_struct(value), module, constraints, depth)

  def typed_value(value, type, constraints, depth) when is_map(value) do
    fields = schema_fields(type, constraints)
    redact_fields(value, fields, depth)
  end

  def typed_value(value, _type, _constraints, _depth), do: value

  # Bound collection traversal before projecting nested resource metadata. The
  # inspector retains only thirty items, regardless of the source list's size.
  defp project_list(values, type, constraints, depth) do
    {retained, remainder} = Enum.split(values, 30)
    projected = Enum.map(retained, &typed_value(&1, type, constraints, depth + 1))
    if remainder == [], do: projected, else: projected ++ ["[list truncated]"]
  end

  def error(error, "[redacted]"), do: redact_error(error, :all)
  def error(error, redacted_input), do: redact_error(error, redacted_names(redacted_input))

  defp redacted_names(value) when is_map(value) do
    Enum.flat_map(value, fn {key, value} ->
      if value == "[redacted]" && (is_atom(key) || is_binary(key)),
        do: [to_string(key)],
        else: redacted_names(value)
    end)
  end

  defp redacted_names(value) when is_list(value), do: Enum.flat_map(value, &redacted_names/1)
  defp redacted_names(_), do: []

  defp redact_error(error, names) when is_map(error) do
    error =
      if is_list(Map.get(error, :errors)),
        do:
          Map.update!(error, :errors, &Enum.map(&1, fn child -> redact_error(child, names) end)),
        else: error

    field = Map.get(error, :field)

    if names == :all || ((is_atom(field) || is_binary(field)) && to_string(field) in names) do
      Enum.reduce([:value, :vars, :private_vars], error, fn key, error ->
        if Map.has_key?(error, key),
          do: Map.put(error, key, if(key == :value, do: "[redacted]", else: [])),
          else: error
      end)
    else
      error
    end
  end

  defp redact_error(error, _names), do: error

  defp schema_fields(type, constraints)
       when type in [nil, :map, :term, Ash.Type.Map, Ash.Type.Term],
       do: constrained_fields(constraints)

  defp schema_fields(type, constraints) do
    cond do
      Ash.Resource.Info.resource?(type) ->
        Ash.Resource.Info.fields(type, [:attributes, :calculations, :aggregates])

      Aikido.Signal.Routes.valid_definition?(type) ->
        Aikido.Signal.Info.schema(type)

      Spark.Dsl.is?(type, Ash.TypedStruct.Dsl) ->
        Ash.TypedStruct.Info.fields(type)

      Ash.Type.NewType.new_type?(type) ->
        schema_fields(type.subtype_of(), Keyword.merge(type.subtype_constraints(), constraints))

      true ->
        constrained_fields(constraints)
    end
  end

  defp constrained_fields(constraints) do
    Enum.map(Keyword.get(constraints, :fields, []), fn {name, opts} ->
      Map.new(Keyword.put(opts, :name, name))
    end)
  end

  defp redact_fields(value, fields, depth) when is_map(value) do
    fields = Map.new(fields, &{to_string(&1.name), &1})

    Map.new(value, fn {key, value} ->
      field = if is_atom(key) || is_binary(key), do: fields[to_string(key)]

      value =
        cond do
          field && Map.get(field, :sensitive?, false) -> "[redacted]"
          field -> typed_value(value, field.type, Map.get(field, :constraints) || [], depth + 1)
          true -> typed_value(value, nil, [], depth + 1)
        end

      {key, value}
    end)
  end

  defp redact_fields(value, _fields, _depth), do: value
end
