defmodule Aikido.Dsl.Schema do
  @moduledoc false

  @attribute %Spark.Dsl.Entity{
    name: :attribute,
    target: Ash.Resource.Attribute,
    args: [:name, :type],
    schema: Ash.Resource.Attribute.attribute_schema(),
    transform: {Ash.Resource.Attribute, :transform, []}
  }

  def attribute_section(name \\ :schema),
    do: %Spark.Dsl.Section{name: name, entities: [@attribute]}

  def create_typed_struct_module(module, fields) do
    fields =
      for attribute <- fields do
        options =
          attribute
          |> Map.take([:constraints, :allow_nil?, :default, :description])
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        quote do
          field unquote(attribute.name), unquote(attribute.type), unquote(Macro.escape(options))
        end
      end

    Module.create(
      module,
      quote do
        use Ash.TypedStruct

        typed_struct do
          (unquote_splicing(fields))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

end
