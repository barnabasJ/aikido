defmodule Aikido.Slices.AiReact.Transformers.RegisterContribution do
  @moduledoc """
  Registers `Aikido.Slices.AiReact` as the slice module that owns the contributed
  `react do … end` section in the host agent's `:aikido_contributed_sections`
  map.

  `Aikido.Dsl.Agent.Transformers.WalkExtensions`
  reads this map to know which contributed-section opts to merge into a
  given slice's instance config. By persisting `%{Aikido.Slices.AiReact => :react}`,
  this transformer makes the `react do model … end` block opts flow into
  ReAct's slice config when the user mounts
  `slices do slice :react, Aikido.Slices.AiReact end`.

  Pure `Spark.Dsl.Transformer.persist/3` — no Aikido-custom callbacks.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def before?(Aikido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def before?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    contributed = Transformer.get_persisted(dsl_state, :aikido_contributed_sections, %{})

    {:ok,
     Transformer.persist(
       dsl_state,
       :aikido_contributed_sections,
       Map.put(contributed, Aikido.Slices.AiReact, :react)
     )}
  end
end
