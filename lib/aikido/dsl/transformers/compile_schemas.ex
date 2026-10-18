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
      Enum.reduce([:action, :agent, :slice, :sensor], dsl, fn section, dsl ->
        Enum.reduce([:schema, :output_schema, :config_schema], dsl, fn key, dsl ->
          path = [section, key]

          if Map.has_key?(dsl, path) do
            fields =
              path |> then(&Transformer.get_entities(dsl, &1)) |> Aikido.Ash.Attributes.fields()

            if section == :action && key == :schema do
              dsl
              |> Aikido.Dsl.Schema.define_typed_struct_on_host(fields)
              |> Transformer.set_option([section], key, module)
            else
              contract = Module.concat(module, Macro.camelize("#{section}_#{key}"))
              contract = Aikido.Dsl.Schema.create_typed_struct_module(contract, fields)
              Transformer.set_option(dsl, [section], key, contract)
            end
          else
            dsl
          end
        end)
      end)

    dsl =
      if Map.has_key?(dsl, [:action]) && Transformer.get_option(dsl, [:action], :schema, []) == [] do
        dsl
        |> Aikido.Dsl.Schema.define_typed_struct_on_host([])
        |> Transformer.set_option([:action], :schema, module)
      else
        dsl
      end

    {:ok, dsl}
  end
end
