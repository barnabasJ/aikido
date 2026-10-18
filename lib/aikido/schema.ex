defmodule Aikido.Schema do
  @moduledoc """
  Metadata and native Ash validation for compiled DSL contracts.

  Ash resources own their attributes, changesets, and defaults. Plain Aikido DSL
  hosts compile inline contracts with Ash.TypedStruct; action inputs live on
  the action module itself, while other plain contracts use nested modules.
  This boundary projects generated typed structs into the plain maps used by
  the pure agent runtime; Ash owns all casting and constraint validation.
  Anonymous field lists use native Ash map constraints; declare defaults in
  `schema do` or `Ash.TypedStruct`.
  """
  @type t :: keyword() | module()

  def fields(schema) when is_list(schema) do
    cond do
      Enum.all?(schema, fn entry -> match?({_, opts} when is_list(opts), entry) end) ->
        schema

      Enum.all?(schema, &is_struct/1) ->
        Enum.map(schema, fn field ->
          {field.name,
           field
           |> Map.from_struct()
           |> Map.take([:type, :constraints, :default, :allow_nil?, :description])
           |> Enum.reject(fn {_key, value} -> is_nil(value) end)}
        end)

      true ->
        []
    end
  end

  def fields(module) when is_atom(module) and not is_nil(module) do
    cond do
      Spark.Dsl.is?(module, Ash.Resource) ->
        fields(Ash.Resource.Info.attributes(module))

      Ash.TypedStruct.Dsl in Spark.extensions(module) ->
        module
        |> Spark.Dsl.Extension.get_entities([:typed_struct])
        |> fields()

      true ->
        if function_exported?(module, :__ash_fields__, 0), do: module.__ash_fields__(), else: []
    end
  end

  def fields(_), do: []

  def keys(schema), do: schema |> fields() |> Keyword.keys()

  def defaults(nil), do: %{}

  def defaults(schema) when is_atom(schema) do
    if Spark.Dsl.is?(schema, Ash.Resource) do
      {:ok, record} =
        schema
        |> Ash.Changeset.for_create(:create, %{})
        |> Ash.Changeset.apply_attributes(force?: true)

      names =
        for attribute <- Ash.Resource.Info.attributes(schema),
            !is_nil(attribute.default),
            do: attribute.name

      Map.take(record, names)
    else
      names = for {name, field} <- fields(schema), !is_nil(field[:default]), do: name
      schema |> struct() |> Map.take(names)
    end
  end

  def defaults(_schema), do: %{}

  def cast(schema, data, opts \\ [])
  def cast([], data, _opts), do: {:ok, data}

  def cast(schema, data, opts) do
    result =
      cond do
        is_atom(schema) && Spark.Dsl.is?(schema, Ash.Resource) ->
          changeset = Ash.Changeset.for_create(schema, :create, data, skip_unknown_inputs: [:*])

          case Ash.Changeset.apply_attributes(changeset) do
            {:ok, record} -> {:ok, contract_to_map(record)}
            {:error, errors} -> {:error, Ash.Error.to_error_class(errors)}
          end

        is_atom(schema) && function_exported?(schema, :__aikido_contract__, 0) ->
          case schema.new(Map.new(data)) do
            {:ok, value} -> {:ok, value}
            {:error, errors} -> {:error, Ash.Error.to_error_class(errors)}
          end

        is_atom(schema) ->
          constraints = [instance_of: schema, fields: native_fields(fields(schema))]
          values = Map.merge(Map.from_struct(struct(schema)), Map.new(data))
          cast_value(:struct, values, constraints)

        is_list(schema) ->
          cast_value(:map, Map.new(data), fields: native_fields(schema))
      end

    case result do
      {:ok, value} ->
        value = contract_to_map(value)

        if opts[:preserve_unknown?] && is_map(value),
          do: {:ok, Map.merge(Map.new(data), value)},
          else: {:ok, value}

      result ->
        result
    end
  end

  def cast!(schema, data) do
    case cast(schema, data) do
      {:ok, value} -> value
      {:error, errors} -> raise Ash.Error.to_error_class(errors)
    end
  end

  def cast_value(type, value, constraints \\ []) do
    with {:ok, constraints} <- Ash.Type.init(type, constraints),
         {:ok, value} <- Ash.Type.cast_input(type, value, constraints),
         {:ok, value} <- Ash.Type.apply_constraints(type, value, constraints) do
      {:ok, value}
    else
      :error -> {:error, [[message: "has an invalid type"]]}
      error -> error
    end
  end

  def to_struct(value, _opts, module), do: struct(module, value)

  defp contract_to_map(%module{} = value) do
    if function_exported?(module, :__aikido_contract__, 0),
      do: value |> Map.take(keys(module)) |> contract_to_map(),
      else: value
  end

  defp contract_to_map(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, contract_to_map(value)} end)

  defp contract_to_map(value) when is_list(value), do: Enum.map(value, &contract_to_map/1)
  defp contract_to_map(value), do: value

  defp native_fields(fields),
    do:
      Enum.map(fields, fn {key, opts} ->
        {key, Enum.reject(opts, fn {key, value} -> key == :default || is_nil(value) end)}
      end)

  def transform(value, nil), do: {:ok, value}

  def transform(value, {module, function, args}) do
    case apply(module, function, [value, [] | args]) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, error}
      value -> {:ok, value}
    end
  end

  def validate_enum(value, _opts, values) do
    if value in values, do: :ok, else: {:error, "must be one of #{inspect(values)}"}
  end
end
