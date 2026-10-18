defmodule Aikido.Ash.Transformers.Slice do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    declared = Transformer.get_entities(dsl, [:slice, :schema])
    existing = Ash.Resource.Info.attributes(dsl)
    names = Enum.map(declared ++ existing, & &1.name)

    if length(names) != length(Enum.uniq(names)) do
      raise Spark.Error.DslError,
        message: "Slice schema and resource attributes must have unique names",
        path: [:slice, :schema]
    end

    dsl = Enum.reduce(declared, dsl, &Transformer.add_entity(&2, [:attributes], &1))
    routes = Transformer.get_entities(dsl, [:slice])
    schedules = Transformer.get_entities(dsl, [:schedules])

    cond do
      !Ash.Resource.Info.embedded?(dsl) ->
        error("Aikido.Ash.Slice requires data_layer: :embedded")

      Enum.any?(routes ++ schedules, &invalid_action?(dsl, &1.action)) ->
        error(
          "Slice routes require generic Ash actions with a :state argument and Aikido.ActionResult return type"
        )

      true ->
        resource = Transformer.get_persisted(dsl, :module)
        config = Transformer.get_entities(dsl, [:slice, :config_schema])
        dsl = Transformer.persist(dsl, :aikido_slice_schema, resource)

        if config == [] do
          {:ok, dsl}
        else
          contract =
            Aikido.Dsl.Schema.create_typed_struct_module(Module.concat(resource, Config), config)

          {:ok, Transformer.set_option(dsl, [:slice], :config_schema, contract)}
        end
    end
  end

  defp invalid_action?(dsl, name) do
    case Ash.Resource.Info.action(dsl, name) do
      %{type: :action, returns: Aikido.ActionResult, arguments: arguments} ->
        !Enum.any?(arguments, &(&1.name == :state))

      _ ->
        true
    end
  end

  defp error(message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [:slice])}
end
