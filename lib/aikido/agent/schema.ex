defmodule Aikido.Agent.Schema do
  @moduledoc false

  def merge_with_plugins(nil, []), do: nil
  def merge_with_plugins(base, []), do: base

  def merge_with_plugins(base, slices) do
    fields =
      for %{path: path, schema: schema} <- slices, not is_nil(schema) do
        opts =
          if is_atom(schema),
            do: [type: schema],
            else: [type: :map, constraints: [fields: schema]]

        {path,
         Keyword.put(opts, :allow_nil?, match?({:error, _}, Aikido.Schema.cast(schema, %{})))}
      end

    Keyword.merge(Aikido.Schema.fields(base), fields)
  end

  def known_keys(schema), do: Aikido.Schema.keys(schema)
  def defaults_from_schema(schema), do: Aikido.Schema.defaults(schema)
end
