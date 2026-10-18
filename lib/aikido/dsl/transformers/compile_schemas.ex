defmodule Aikido.Dsl.Transformers.CompileSchemas do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl) do
    module = Transformer.get_persisted(dsl, :module)

    dsl =
      Enum.reduce([:agent, :slice], dsl, fn section, dsl ->
        case Transformer.get_persisted(dsl, :"aikido_#{section}_schema") do
          nil -> dsl
          schema -> Transformer.set_option(dsl, [section], :schema, schema)
        end
      end)

    dsl =
      Enum.reduce([:agent, :slice, :sensor], dsl, fn section, dsl ->
        Enum.reduce([:schema, :config_schema], dsl, fn key, dsl ->
          path = [section, key]

          if Map.has_key?(dsl, path) do
            fields =
              Transformer.get_entities(dsl, path)

            contract = Module.concat(module, Macro.camelize("#{section}_#{key}"))
            contract = Aikido.Dsl.Schema.create_typed_struct_module(contract, fields)
            Transformer.set_option(dsl, [section], key, contract)
          else
            dsl
          end
        end)
      end)

    {:ok, dsl}
  end
end
