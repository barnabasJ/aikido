defmodule Aikido.Durable.BootstrapCallbacks do
  @moduledoc false

  # Record only native scalar conversions actually performed after the owning
  # path codec. Reverse those conversions before that codec's reinstate callback.
  def externalize(values, attributes),
    do: transform_fields(values, attributes, [], :externalize, false)

  # Run after the paired codec has observed original field presence. Only an
  # optional embedded resource attribute with a literal nil default is equivalent
  # to omission; all other input keeps its native create semantics.
  def normalize_optional_nil(values, owner, attributes) do
    case transform_fields(values, attributes, [], :normalize, Ash.Resource.Info.embedded?(owner)) do
      {:ok, value, _locations} -> {:ok, value}
      error -> error
    end
  end

  def reinstate(values, locations) do
    Enum.reduce_while(locations, {:ok, values}, fn {path, constraints}, {:ok, result} ->
      case restore_location(result, path, constraints) do
        {:ok, value} -> {:cont, {:ok, value}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp transform_fields(values, attributes, path, mode, embedded?) when is_map(values) do
    Enum.reduce_while(attributes, {:ok, values, []}, fn attribute, {:ok, result, locations} ->
      case field_key(result, attribute.name) do
        nil ->
          {:cont, {:ok, result, locations}}

        key ->
          if mode == :normalize && omittable_nil?(result, key, attribute, embedded?) do
            result = if is_struct(result), do: Map.from_struct(result), else: result

            {:cont,
             {:ok, Map.drop(result, [attribute.name, to_string(attribute.name)]), locations}}
          else
            case transform_value(
                   Map.fetch!(result, key),
                   attribute.type,
                   attribute.constraints || [],
                   Map.get(attribute, :initialized?, true),
                   [{:key, key} | path],
                   mode
                 ) do
              {:ok, value, converted} ->
                {:cont, {:ok, Map.put(result, key, value), locations ++ converted}}

              {:error, _} = error ->
                {:halt, error}
            end
          end
      end
    end)
  end

  defp transform_fields(value, _attributes, _path, _mode, _embedded?), do: {:ok, value, []}

  defp transform_value(nil, _type, _constraints, _initialized?, _path, _mode), do: {:ok, nil, []}

  defp transform_value(value, type, constraints, initialized?, path, mode),
    do: transform_type(value, Ash.Type.get_type(type), constraints, initialized?, path, mode)

  defp transform_type(values, {:array, type}, constraints, initialized?, path, mode)
       when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {value, index}, {:ok, result, locations} ->
      case transform_value(
             value,
             type,
             constraints[:items] || [],
             initialized?,
             [
               {:index, index} | path
             ],
             mode
           ) do
        {:ok, value, converted} -> {:cont, {:ok, [value | result], locations ++ converted}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values, locations} -> {:ok, Enum.reverse(values), locations}
      error -> error
    end
  end

  defp transform_type(value, {:array, _type}, _constraints, _initialized?, _path, _mode),
    do: {:ok, value, []}

  defp transform_type(value, Ash.Type.Function, constraints, _initialized?, path, :externalize) do
    cond do
      !is_function(value) ->
        {:ok, value, []}

      !constraints[:mfa] ->
        {:error, :nonportable_bootstrap_callback}

      true ->
        constraints = Keyword.take(constraints, [:mfa, :arity])

        case Ash.Type.dump_to_embedded(:function, value, constraints) do
          {:ok, callback} -> {:ok, callback, [{Enum.reverse(path), constraints}]}
          _ -> {:error, :invalid_portable_bootstrap_callback}
        end
    end
  end

  defp transform_type(value, type, constraints, initialized?, path, mode) do
    cond do
      Ash.Type.NewType.new_type?(type) ->
        constraints =
          if initialized? && !type.lazy_init?(),
            do: constraints,
            else: Keyword.merge(constraints, type.subtype_constraints())

        transform_value(
          value,
          type.subtype_of(),
          constraints,
          initialized? && !type.lazy_init?(),
          path,
          mode
        )

      Spark.Dsl.is?(type, Ash.Resource) ->
        transform_fields(
          value,
          Ash.Resource.Info.attributes(type),
          path,
          mode,
          Ash.Resource.Info.embedded?(type)
        )

      type in [Ash.Type.Map, Ash.Type.Struct] && is_list(constraints[:fields]) ->
        attributes =
          Enum.map(constraints[:fields], fn {name, field} ->
            %{
              name: name,
              type: field[:type],
              constraints: field[:constraints] || [],
              initialized?: initialized? && Keyword.get(field, :init?, true)
            }
          end)

        transform_fields(value, attributes, path, mode, false)

      type == Ash.Type.Struct && !is_nil(constraints[:instance_of]) &&
          Spark.Dsl.is?(constraints[:instance_of], Ash.Resource) ->
        transform_fields(
          value,
          Ash.Resource.Info.attributes(constraints[:instance_of]),
          path,
          mode,
          Ash.Resource.Info.embedded?(constraints[:instance_of])
        )

      true ->
        {:ok, value, []}
    end
  end

  defp omittable_nil?(values, key, %Ash.Resource.Attribute{} = attribute, true) do
    Map.fetch!(values, key) == nil && attribute.allow_nil? == true && attribute.default == nil &&
      function_type?(Ash.Type.get_type(attribute.type))
  end

  defp omittable_nil?(_values, _key, _attribute, _embedded?), do: false

  defp function_type?(Ash.Type.Function), do: true

  defp function_type?(type) do
    Ash.Type.NewType.new_type?(type) && function_type?(Ash.Type.get_type(type.subtype_of()))
  end

  defp restore_location(value, [], constraints) do
    case Ash.Type.cast_from_embedded(:function, value, constraints) do
      {:ok, callback} -> {:ok, callback}
      _ -> {:error, :invalid_portable_bootstrap_callback}
    end
  end

  defp restore_location(value, [{:key, key} | rest], constraints) when is_map(value) do
    with {:ok, child} <- Map.fetch(value, key),
         {:ok, restored} <- restore_location(child, rest, constraints) do
      {:ok, Map.put(value, key, restored)}
    else
      _ -> {:error, :invalid_bootstrap_callback_location}
    end
  end

  defp restore_location(value, [{:index, index} | rest], constraints) when is_list(value) do
    with {:ok, child} <- Enum.fetch(value, index),
         {:ok, restored} <- restore_location(child, rest, constraints) do
      {:ok, List.replace_at(value, index, restored)}
    else
      _ -> {:error, :invalid_bootstrap_callback_location}
    end
  end

  defp restore_location(_value, _path, _constraints),
    do: {:error, :invalid_bootstrap_callback_location}

  defp field_key(values, name) do
    cond do
      Map.has_key?(values, name) -> name
      Map.has_key?(values, to_string(name)) -> to_string(name)
      true -> nil
    end
  end
end
