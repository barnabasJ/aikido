defmodule Aikido.Slice.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    with {:ok, dsl} <- Aikido.Signal.Routes.expand(dsl, :slice) do
      build(dsl)
    end
  end

  defp build(dsl) do
    declared = Transformer.get_entities(dsl, [:slice, :schema])
    dsl = Enum.reduce(declared, dsl, &Transformer.add_entity(&2, [:attributes], &1))

    accepted =
      dsl
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.writable?)
      |> Enum.map(& &1.name)

    {:ok, dsl} =
      Ash.Resource.Builder.add_new_action(dsl, :create, :create,
        primary?: true,
        accept: accepted
      )

    {:ok, dsl} =
      Ash.Resource.Builder.add_new_action(dsl, :update, :update,
        primary?: true,
        accept: accepted
      )

    {:ok, dsl}
  end
end
