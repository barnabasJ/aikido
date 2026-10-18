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
      for {name, opts} <- Aikido.Schema.fields(fields) do
        options = Keyword.take(opts, [:constraints, :allow_nil?, :default, :description])

        quote do
          field unquote(name), unquote(opts[:type]), unquote(Macro.escape(options))
        end
      end

    Module.create(
      module,
      quote do
        use Ash.TypedStruct

        @doc false
        def __aikido_contract__, do: true

        typed_struct do
          (unquote_splicing(fields))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  def define_typed_struct_on_host(dsl, fields) do
    alias Spark.Dsl.Transformer

    dsl =
      Enum.reduce(fields, dsl, fn {name, options}, dsl ->
        field =
          struct!(
            Ash.TypedStruct.Field,
            [name: name] ++
              Keyword.take(options, [:type, :constraints, :allow_nil?, :default, :description])
          )

        Transformer.add_entity(dsl, [:typed_struct], field)
      end)

    dsl
    |> Transformer.eval([], Ash.TypedStruct.Dsl.after_define())
    |> Transformer.eval(
      [],
      quote do
        @doc false
        def __aikido_contract__, do: true
        @doc false
        def __ash_fields__, do: unquote(Macro.escape(fields))
      end
    )
  end
end
