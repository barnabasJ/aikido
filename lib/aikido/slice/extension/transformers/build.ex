defmodule Aikido.Slice.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    with {:ok, dsl} <- Aikido.Signal.Routes.expand(dsl, :slice) do
      add_state_attributes_and_default_actions(dsl)
    end
  end

  defp add_state_attributes_and_default_actions(dsl) do
    dsl = add_declared_state_attributes(dsl)
    accepted = writable_attribute_names(dsl)

    with {:ok, dsl} <- add_default_create_action(dsl, accepted) do
      Ash.Resource.Builder.add_new_action(dsl, :update, :update,
        primary?: true,
        accept: accepted
      )
    end
  end

  defp add_declared_state_attributes(dsl) do
    dsl
    |> Transformer.get_entities([:slice, :schema])
    |> Enum.reduce(dsl, &Transformer.add_entity(&2, [:attributes], &1))
  end

  defp writable_attribute_names(dsl) do
    dsl
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(& &1.writable?)
    |> Enum.map(& &1.name)
  end

  defp add_default_create_action(dsl, accepted) do
    Ash.Resource.Builder.add_new_action(dsl, :create, :create,
      primary?: true,
      accept: accepted,
      changes: initialization_changes(dsl)
    )
  end

  defp initialization_changes(dsl) do
    case Transformer.get_option(dsl, [:slice], :initialize) do
      nil -> []
      change -> [Ash.Resource.Builder.build_action_change(change)]
    end
  end
end
