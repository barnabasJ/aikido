defmodule Aikido.Ash.Transformers.Domain do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    entries = Transformer.get_entities(dsl, [:agents])
    names = Enum.map(entries, & &1.name)

    cond do
      length(names) != length(Enum.uniq(names)) ->
        error("Domain agent names must be unique")

      Enum.any?(entries, &(Aikido.Ash.Agent not in Spark.extensions(&1.resource))) ->
        error("Domain agents must use the Aikido.Ash.Agent extension")

      true ->
        register(dsl, entries)
    end
  end

  defp register(dsl, entries) do
    dsl =
      Enum.reduce(entries, dsl, fn entry, dsl ->
        definitions =
          Enum.map(Ash.Resource.Info.actions(entry.resource), fn action ->
            %Ash.Resource.Interface{
              name: :"#{entry.name}_#{action.name}",
              action: action.name,
              args: if(Enum.any?(action.arguments, &(&1.name == :agent)), do: [:agent], else: []),
              require_reference?: false,
              get?: false,
              not_found_error?: true
            }
          end)

        Transformer.add_entity(dsl, [:resources], %Ash.Domain.Dsl.ResourceReference{
          resource: entry.resource,
          definitions: definitions
        })
      end)

    {:ok, dsl}
  end

  defp error(message) do
    {:error, Spark.Error.DslError.exception(message: message, path: [:agents])}
  end
end
