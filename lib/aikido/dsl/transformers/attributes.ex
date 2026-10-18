defmodule Aikido.Dsl.Transformers.Attributes do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl) do
    module = Transformer.get_persisted(dsl, :module)
    section = Enum.find([:agent, :slice, :sensor], &Map.has_key?(dsl, [&1]))
    declared = Transformer.get_entities(dsl, [section, :schema])
    dsl = Enum.reduce(declared, dsl, &Transformer.add_entity(&2, [:attributes], &1))

    {:ok, create} =
      Ash.Resource.Builder.build_action(:create, :create,
        primary?: true,
        accept: Enum.map(Ash.Resource.Info.attributes(dsl), & &1.name)
      )

    dsl = Transformer.add_entity(dsl, [:actions], create)
    resource = Transformer.get_persisted(dsl, :aikido_agent_schema, module)

    dsl =
      if Map.has_key?(dsl, [section, :schema]) ||
           Transformer.get_persisted(dsl, :aikido_agent_schema),
         do: Transformer.set_option(dsl, [section], :schema, resource),
         else: dsl

    dsl = configure(dsl, section, module)
    names = Enum.map(declared, & &1.name)

    {:ok,
     Transformer.eval(
       dsl,
       [],
       quote do
         @doc false
         def __aikido_state_fields__, do: unquote(names)
       end
     )}
  end

  def configure(dsl, section, module) do
    fields = Transformer.get_entities(dsl, [section, :config_schema])

    if fields == [] do
      dsl
    else
      arguments =
        Enum.map(fields, fn field ->
          opts =
            field
            |> Map.take([:allow_nil?, :constraints, :default, :description])
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)

          {:ok, argument} =
            Ash.Resource.Builder.build_action_argument(field.name, field.type, opts)

          argument
        end)

      {:ok, action} =
        Ash.Resource.Builder.build_action(:action, :__aikido_config__,
          returns: :map,
          arguments: arguments,
          run: Aikido.Config,
          public?: false
        )

      dsl
      |> Transformer.add_entity([:actions], action)
      |> Transformer.set_option([section], :config_schema, {module, :__aikido_config__})
    end
  end
end
