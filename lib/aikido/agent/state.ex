defmodule Aikido.Agent.State do
  @moduledoc false

  def merge(state, changes) when is_list(changes), do: merge(state, Map.new(changes))
  def merge(state, changes) when is_map(changes), do: DeepMerge.deep_merge(state, changes)

  def validate(state, schema, opts \\ [])
  def validate(state, schema, _opts) when schema in [nil, []], do: {:ok, state}

  def validate(state, fields, opts) when is_list(fields) do
    inputs =
      Enum.reduce(fields, state, fn {key, options}, inputs ->
        value = Map.get(inputs, key)
        resource = options[:type]

        if is_map(value) && !is_struct(value) && Ash.Resource.Info.resource?(resource) do
          Map.put(
            inputs,
            key,
            Map.take(value, Enum.to_list(Ash.Resource.Info.attribute_names(resource)))
          )
        else
          inputs
        end
      end)

    with {:ok, constraints} <- Ash.Type.init(:map, fields: fields),
         {:ok, value} <- Ash.Type.cast_input(:map, inputs, constraints),
         {:ok, value} <- Ash.Type.apply_constraints(:map, value, constraints) do
      value =
        Map.new(value, fn {key, cast} ->
          original = Map.get(state, key)

          if is_map(original) && !is_struct(original) && is_struct(cast) do
            fields =
              if Ash.Resource.Info.resource?(cast.__struct__),
                do:
                  Map.take(cast, Enum.to_list(Ash.Resource.Info.attribute_names(cast.__struct__))),
                else: Map.from_struct(cast)

            {key, if(opts[:strict], do: fields, else: Map.merge(original, fields))}
          else
            {key, cast}
          end
        end)

      {:ok, if(opts[:strict], do: value, else: Map.merge(state, value))}
    end
  end

  def validate(state, schema, opts) do
    if Ash.Resource.Info.resource?(schema) do
      path =
        if Aikido.Ash.Agent in Spark.extensions(schema),
          do: Aikido.Ash.Runtime.option(schema, :path)

      fields = schema.__aikido_state_fields__()

      attributes =
        Map.merge(
          Map.take(state, Ash.Resource.Info.attribute_names(schema) |> Enum.to_list()),
          Map.take(Map.get(state, path, %{}), fields)
        )

      action = %Ash.Resource.Actions.Create{
        name: :validate_state,
        accept: Ash.Resource.Info.attribute_names(schema) |> Enum.to_list()
      }

      changeset =
        schema |> Ash.Changeset.new() |> Ash.Changeset.force_change_attributes(attributes)

      case changeset
           |> Ash.Changeset.for_create(action, %{}, require?: false)
           |> Ash.Changeset.require_values(
             :create,
             false,
             Enum.reject(Ash.Resource.Info.attributes(schema), & &1.allow_nil?)
           )
           |> Ash.Changeset.apply_attributes() do
        {:ok, record} ->
          if is_nil(path) do
            values = Map.take(record, fields)
            {:ok, if(opts[:strict], do: values, else: Map.merge(state, values))}
          else
            projected = Map.take(record, Map.keys(state) -- [path])
            own = Map.take(record, fields)
            own = if opts[:strict], do: own, else: Map.merge(Map.get(state, path, %{}), own)
            {:ok, state |> Map.merge(projected) |> Map.put(path, own)}
          end

        {:error, error} ->
          {:error, Ash.Error.to_error_class(error)}
      end
    else
      case Ash.Type.cast_input(schema, state) do
        {:ok, value} ->
          value = if is_struct(value), do: Map.from_struct(value), else: value
          {:ok, if(opts[:strict], do: value, else: Map.merge(state, value))}

        error ->
          error
      end
    end
  end
end
