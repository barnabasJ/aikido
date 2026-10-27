defmodule Aikido.Jido.Schema do
  @moduledoc """
  Maps the supported Zoi input shapes into native Ash argument contracts.

  Jido still receives the original parameters and applies its complete Zoi
  validation, including refinements, transforms, strictness and default rules.
  Unsupported shapes fail during compilation instead of becoming `:term`.
  """

  @reserved [:server, :runtime_options, :signal_options]

  def arguments!(%Zoi.Types.Map{fields: fields}, defaults) when is_list(fields) do
    Enum.map(fields, fn {name, schema} ->
      unless is_atom(name) and name not in @reserved do
        raise ArgumentError, "unsupported Jido input key #{inspect(name)}"
      end

      {type, constraints, nullable?} = type!(schema)
      default = Map.get(defaults, name, Zoi.Types.Meta.default(schema.meta))
      has_default? = Map.has_key?(defaults, name) or Zoi.Types.Meta.default?(schema.meta)

      %{
        name: name,
        type: type,
        constraints: constraints,
        description: schema.meta.description,
        allow_nil?: nullable? or schema.meta.required == false or has_default?,
        default: if(has_default?, do: {:value, default}, else: nil)
      }
    end)
  end

  def arguments!(schema, _defaults) do
    raise ArgumentError,
          "Jido adapter requires a Zoi object input schema, got: #{inspect(schema)}"
  end

  def type!(%Zoi.Types.Integer{} = s),
    do: {:integer, bounds(s, [:gte, :lte], [:min, :max]), false}

  def type!(%Zoi.Types.Float{} = s),
    do: {:float, bounds(s, [:gte, :lte], [:min, :max]), false}

  def type!(%Zoi.Types.String{} = s),
    do:
      {:string,
       bounds(s, [:min_length, :max_length], [:min_length, :max_length]) ++
         [trim?: false, allow_empty?: true, length_count: :graphemes], false}

  def type!(%Zoi.Types.Boolean{}), do: {:boolean, [], false}
  def type!(%Zoi.Types.Atom{}), do: {:atom, [], false}
  def type!(%Zoi.Types.Any{}), do: {:term, [], true}

  def type!(%Zoi.Types.Map{fields: fields}) when is_list(fields) do
    fields =
      Enum.map(arguments!(Zoi.object(Map.new(fields)), %{}), fn arg ->
        {arg.name, [type: arg.type, constraints: arg.constraints, allow_nil?: arg.allow_nil?]}
      end)

    {:map, [fields: fields, preserve_nil_values?: true], false}
  end

  def type!(%Zoi.Types.Map{}), do: {:map, [preserve_nil_values?: true], false}
  def type!(%Zoi.Types.Date{}), do: {:date, [], false}
  def type!(%Zoi.Types.DateTime{}), do: {:utc_datetime_usec, [], false}

  def type!(%Zoi.Types.Enum{values: values}) when is_list(values) do
    values = Enum.map(values, fn {_key, value} -> value end)

    cond do
      Enum.all?(values, &is_atom/1) ->
        {:atom, [one_of: values], false}

      Enum.all?(values, &is_binary/1) ->
        expression = values |> Enum.map(&Regex.escape/1) |> Enum.join("|")

        {:string,
         [
           match: Regex.compile!("\\A(?:#{expression})\\z"),
           trim?: false,
           allow_empty?: true,
           length_count: :graphemes
         ], false}

      true ->
        unsupported!(values)
    end
  end

  def type!(%Zoi.Types.Array{inner: inner} = s) do
    {type, constraints, nullable?} = type!(inner)

    {{:array, type},
     [items: constraints, nil_items?: nullable?] ++
       bounds(s, [:min_length, :max_length], [:min_length, :max_length]), false}
  end

  def type!(%Zoi.Types.Union{schemas: schemas} = schema) do
    case Enum.reject(schemas, &match?(%Zoi.Types.Null{}, &1)) do
      [inner] when length(schemas) == 2 ->
        {type, constraints, _} = type!(inner)
        {type, constraints, true}

      _ ->
        unsupported!(schema)
    end
  end

  def type!(schema), do: unsupported!(schema)

  defp bounds(schema, zoi_keys, ash_keys) do
    Enum.zip(zoi_keys, ash_keys)
    |> Enum.flat_map(fn {source, target} ->
      case Map.get(schema, source) do
        {value, _options} -> [{target, value}]
        nil -> []
      end
    end)
  end

  defp unsupported!(schema),
    do: raise(ArgumentError, "unsupported Zoi schema in Jido adapter: #{inspect(schema)}")
end
