defmodule Aikido.Dsl.Transformers.Attributes do
  @moduledoc false
  alias Spark.Dsl.Transformer

  def configure(dsl, section, module) do
    fields = Transformer.get_entities(dsl, [section, :config_schema])

    if fields == [] do
      dsl
    else
      arguments =
        Enum.map(fields, fn field ->
          opts =
            field
            |> Map.take([:allow_nil?, :constraints, :default, :description, :sensitive?])
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)

          {:ok, argument} =
            Ash.Resource.Builder.build_action_argument(field.name, field.type, opts)

          argument
        end)

      {:ok, action} =
        Ash.Resource.Builder.build_action(:action, :__aikido_config__,
          returns: :map,
          arguments: arguments,
          run: Aikido.Slice.Config,
          public?: false
        )

      dsl
      |> Transformer.add_entity([:actions], action)
      |> Transformer.set_option([section], :config_schema, {module, :__aikido_config__})
    end
  end
end
