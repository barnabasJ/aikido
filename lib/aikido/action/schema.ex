defmodule Aikido.Action.Schema do
  @moduledoc "Casts Ash field contracts and exports them as JSON Schema for tools."
  @type t :: Aikido.Schema.t() | map()

  def schema_type([]), do: :empty
  def schema_type(schema) when is_list(schema), do: :ash

  def schema_type(%{"type" => "object", "properties" => properties}) when is_map(properties),
    do: :json_schema

  def schema_type(module) when is_atom(module) do
    if Spark.Dsl.is?(module, Ash.Resource) || Ash.Type.ash_type?(module) ||
         function_exported?(module, :__ash_fields__, 0),
       do: :ash,
       else: :unknown
  end

  def schema_type(_), do: :unknown

  def validate(schema, data) do
    case schema_type(schema) do
      :empty -> {:ok, data}
      :ash -> Aikido.Schema.cast(schema, data)
      :json_schema -> {:ok, data}
      :unknown -> {:error, "Unsupported Ash schema"}
    end
  end

  def known_keys(%{"type" => "object"} = schema) do
    for %{atom: atom} <- json_schema_known_key_forms(schema), not is_nil(atom), do: atom
  end

  def known_keys(schema), do: Aikido.Schema.keys(schema)

  def json_schema_known_key_forms(%{"properties" => properties}) do
    Enum.map(properties, fn {key, _} ->
      string = to_string(key)
      atom = if is_atom(key), do: key, else: existing_atom(string)
      %{atom: atom, string: string}
    end)
  end

  def json_schema_known_key_forms(_), do: []

  def validate_config_schema(schema, _opts \\ []) do
    if schema_type(schema) != :unknown,
      do: :ok,
      else: {:error, "must be Ash field definitions, a typed struct, or a JSON Schema map"}
  end

  defmodule Resource do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded
  end

  def to_json_schema(schema, opts \\ [])
  def to_json_schema(%{"type" => _} = schema, _opts), do: schema

  def to_json_schema(schema, opts) do
    arguments =
      Enum.map(Aikido.Schema.fields(schema), fn {name, field} ->
        struct(Ash.Resource.Actions.Argument,
          name: name,
          type: Ash.Type.get_type(field[:type]),
          constraints: field[:constraints] || [],
          allow_nil?: Keyword.get(field, :allow_nil?, true),
          default: field[:default],
          description: field[:description],
          public?: true
        )
      end)

    action = %Ash.Resource.Actions.Action{name: :schema, arguments: arguments}

    nil
    |> AshAi.Tool.Schema.for_action(Resource, action, nil, [],
      strict?: Keyword.get(opts, :strict, false)
    )
    |> then(fn result -> get_in(result, ["properties", "input"]) || result end)
  end

  defp existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
