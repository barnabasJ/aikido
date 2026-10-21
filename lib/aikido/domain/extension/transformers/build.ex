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
    add_resource_interfaces(dsl, Enum.uniq_by(entries, & &1.name))
  end

  defp add_resource_interfaces(dsl, entries) do
    dsl = Enum.reduce(entries, dsl, &add_agent_resource_interfaces/2)
    {:ok, dsl}
  end

  defp add_agent_resource_interfaces(entry, dsl) do
    definitions =
      entry.resource
      |> Ash.Resource.Info.actions()
      |> Enum.filter(& &1.public?)
      |> Enum.map(&public_action_interface(&1, entry.name))

    Transformer.add_entity(dsl, [:resources], %Ash.Domain.Dsl.ResourceReference{
      resource: entry.resource,
      definitions: definitions
    })
  end

  defp public_action_interface(action, agent_name) do
    %Ash.Resource.Interface{
      name: :"#{agent_name}_#{action.name}",
      action: action.name,
      args: if(Enum.any?(action.arguments, &(&1.name == :agent)), do: [:agent], else: []),
      require_reference?: false,
      get?: false,
      not_found_error?: true
    }
  end
end
