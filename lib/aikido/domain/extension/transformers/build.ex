defmodule Aikido.Domain.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    entries = Transformer.get_entities(dsl, [:agents])
    # Preserve declarations for the verifier, but emit each interface name once.
    register(dsl, Enum.uniq_by(entries, & &1.name))
  end

  defp register(dsl, entries) do
    dsl =
      Enum.reduce(entries, dsl, fn entry, dsl ->
        definitions =
          entry.resource
          |> Ash.Resource.Info.actions()
          |> Enum.filter(& &1.public?)
          |> Enum.map(fn action ->
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
end
