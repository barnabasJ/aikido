defmodule Aikido.Slices.Thread.Transformers.RegisterContribution do
  @moduledoc """
  Registers `Aikido.Slices.Thread` as the slice module that owns the contributed
  `thread do … end` section in the host agent's `:aikido_contributed_sections`
  map.

  `Aikido.Dsl.Agent.Transformers.WalkExtensions`
  reads this map to know which contributed-section opts to merge into a
  given slice's instance config. By persisting
  `%{Aikido.Slices.Thread => :thread}`, this transformer makes the
  `thread do … end` block opts flow into the Thread slice's instance
  config when the user mounts `slices do slice :thread, Aikido.Slices.Thread end`.

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
       Map.put(contributed, Aikido.Slices.Thread, :thread)
     )}
  end
end
