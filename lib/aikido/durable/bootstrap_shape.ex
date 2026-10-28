defmodule Aikido.Durable.BootstrapShape do
  @moduledoc false

  # The temporary schema uses native map, array and term types, with native
  # Function validation so raw input cannot masquerade as a stored capture.
  # Resource creation and embedded casts remain after the durable claim.
  def project(values, attributes) when is_map(values) and is_list(attributes) do
    with {:ok, fields} <- structural_fields(attributes, [values]),
         {:ok, constraints} <- Ash.Type.init(:map, fields: fields, preserve_nil_values?: true) do
      Ash.Type.apply_constraints(:map, values, constraints)
    end
  end

  def project(_values, _attributes), do: {:error, :invalid_bootstrap_shape}

  defp structural_fields(attributes, values) do
    Enum.reduce_while(attributes, {:ok, []}, fn attribute, {:ok, fields} ->
      name = attribute.name
      present = field_values(values, name)

      case structural_type(
             attribute.type,
             attribute.constraints || [],
             present,
             Map.get(attribute, :initialized?, true)
           ) do
        {:ok, {type, constraints}} ->
          field = {name, [type: type, constraints: constraints, allow_nil?: true]}
          {:cont, {:ok, [field | fields]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> reverse_fields()
  end

  defp reverse_fields({:ok, fields}), do: {:ok, Enum.reverse(fields)}
  defp reverse_fields(error), do: error

  # No present value can contain unknown fields. Stopping here also prevents an
  # eagerly expanded schema from looping on a recursive embedded declaration.
  defp structural_type(_type, _constraints, [], _initialized?), do: {:ok, {:term, []}}

  defp structural_type(type, constraints, values, initialized?) do
    values = Enum.reject(values, &is_nil/1)

    if values == [] do
      {:ok, {:term, []}}
    else
      expand_type(Ash.Type.get_type(type), constraints, values, initialized?)
    end
  end

  defp expand_type({:array, item_type}, constraints, values, initialized?) do
    if Enum.all?(values, &is_list/1) do
      with {:ok, {type, items}} <-
             structural_type(
               item_type,
               constraints[:items] || [],
               Enum.concat(values),
               initialized?
             ) do
        {:ok, {{:array, type}, [items: items, nil_items?: true, empty_values: []]}}
      end
    else
      {:error, :invalid_bootstrap_array_shape}
    end
  end

  defp expand_type(type, constraints, values, initialized?) do
    cond do
      Ash.Type.NewType.new_type?(type) ->
        # Raw init?: false fields and lazy NewTypes retain declaration metadata,
        # without invoking do_init and eagerly initializing recursive resources.
        constraints =
          if initialized? && !type.lazy_init?(),
            do: constraints,
            else: Keyword.merge(constraints, type.subtype_constraints())

        structural_type(
          type.subtype_of(),
          constraints,
          values,
          initialized? && !type.lazy_init?()
        )

      Spark.Dsl.is?(type, Ash.Resource) ->
        structural_map(Ash.Resource.Info.attributes(type), values)

      type in [Ash.Type.Map, Ash.Type.Struct] ->
        map_shape(type, constraints, values, initialized?)

      type == Ash.Type.Function ->
        validate_functions(values, constraints)

      true ->
        {:ok, {:term, []}}
    end
  end

  # Native Map casts every present field, including nil. Validate nonnil inputs
  # individually, then preserve presence for the owning paired codec.
  defp validate_functions(values, constraints) do
    Enum.reduce_while(values, {:ok, {:term, []}}, fn value, result ->
      with {:ok, cast} <- Ash.Type.cast_input(:function, value, constraints),
           {:ok, _} <- Ash.Type.apply_constraints(:function, cast, constraints) do
        {:cont, result}
      else
        _ -> {:halt, {:error, :invalid_bootstrap_function}}
      end
    end)
  end

  defp map_shape(type, constraints, values, initialized?) when is_list(constraints) do
    case Keyword.fetch(constraints, :fields) do
      {:ok, fields} when is_list(fields) ->
        attributes =
          Enum.map(fields, fn {name, field} ->
            %{
              name: name,
              type: field[:type],
              constraints: field[:constraints] || [],
              initialized?: initialized? && Keyword.get(field, :init?, true)
            }
          end)

        structural_map(attributes, values)

      _ when type == Ash.Type.Struct ->
        instance_shape(constraints[:instance_of], values)

      _ ->
        # An unconstrained map has no declared fields to project.
        {:ok, {:term, []}}
    end
  end

  defp instance_shape(nil, _values), do: {:ok, {:term, []}}

  defp instance_shape(module, values) do
    cond do
      Spark.Dsl.is?(module, Ash.Resource) ->
        structural_map(Ash.Resource.Info.attributes(module), values)

      Code.ensure_loaded?(module) && function_exported?(module, :__info__, 1) ->
        case module.__info__(:struct) do
          fields when is_list(fields) ->
            attributes = Enum.map(fields, &%{name: &1.field, type: :term, constraints: []})
            structural_map(attributes, values)

          _ ->
            {:error, :invalid_bootstrap_struct_schema}
        end

      true ->
        {:error, :invalid_bootstrap_struct_schema}
    end
  end

  defp structural_map(attributes, values) do
    if Enum.all?(values, &is_map/1) do
      with {:ok, fields} <- structural_fields(attributes, values) do
        {:ok, {:map, [fields: fields, preserve_nil_values?: true]}}
      end
    else
      {:error, :invalid_bootstrap_map_shape}
    end
  end

  defp field_values(values, name) do
    Enum.flat_map(values, fn value ->
      case Map.fetch(value, name) do
        {:ok, field} ->
          [field]

        :error ->
          case Map.fetch(value, to_string(name)) do
            {:ok, field} -> [field]
            :error -> []
          end
      end
    end)
  end
end
