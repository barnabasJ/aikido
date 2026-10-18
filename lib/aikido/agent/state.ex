defmodule Aikido.Agent.State do
  @moduledoc false

  def merge(state, changes) when is_list(changes), do: merge(state, Map.new(changes))
  def merge(state, changes) when is_map(changes), do: DeepMerge.deep_merge(state, changes)

  def validate(state, schema, opts \\ [])
  def validate(state, schema, _opts) when schema in [nil, []], do: {:ok, state}

  def validate(state, fields, opts) when is_list(fields) do
    with {:ok, constraints} <- Ash.Type.init(:map, fields: fields),
         {:ok, value} <- Ash.Type.cast_input(:map, state, constraints),
         {:ok, value} <- Ash.Type.apply_constraints(:map, value, constraints) do
      {:ok, if(opts[:strict], do: value, else: Map.merge(state, value))}
    end
  end

  def validate(state, schema, opts) do
    if Ash.Resource.Info.resource?(schema) do
      path = Aikido.Ash.Runtime.option(schema, :path)
      fields = schema.__aikido_state_fields__()
      attributes = Map.merge(Map.take(state, (Ash.Resource.Info.attribute_names(schema) |> Enum.to_list())), Map.get(state, path, %{}))
      action = %Ash.Resource.Actions.Create{name: :validate_state, accept: (Ash.Resource.Info.attribute_names(schema) |> Enum.to_list())}
      changeset = schema |> Ash.Changeset.new() |> Ash.Changeset.force_change_attributes(attributes)

      case changeset
           |> Ash.Changeset.for_create(action, %{}, require?: false)
           |> Ash.Changeset.require_values(:create, false,
             Enum.reject(Ash.Resource.Info.attributes(schema), & &1.allow_nil?))
           |> Ash.Changeset.apply_attributes() do
        {:ok, record} ->
          projected = Map.take(record, Map.keys(state) -- [path])
          {:ok, state |> Map.merge(projected) |> Map.put(path, Map.take(record, fields))}
        {:error, error} -> {:error, Ash.Error.to_error_class(error)}
      end
    else
      case Ash.Type.cast_input(schema, state) do
        {:ok, value} ->
          value = if is_struct(value), do: Map.from_struct(value), else: value
          {:ok, if(opts[:strict], do: value, else: Map.merge(state, value))}
        error -> error
      end
    end
  end
end
