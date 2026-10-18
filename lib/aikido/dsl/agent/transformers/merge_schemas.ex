defmodule Aikido.Dsl.Agent.Transformers.MergeSchemas do
  @moduledoc """
  Merges the agent's base schema (declared in `agent do schema …`) with
  the schemas of every bare-slice instance attached to the agent.
  Persists the merged schema as `:merged_schema`.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def after?(Aikido.Dsl.Agent.Transformers.WalkExtensions), do: true
  def after?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    base_schema =
      Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :schema, [])

    slice_pseudo_specs = Transformer.get_persisted(dsl_state, :slice_pseudo_specs, [])
    path = Transformer.get_option(dsl_state, [:agent], :path)
    own = if path && base_schema, do: [%{path: path, schema: base_schema}], else: []

    merged_schema =
      Transformer.get_persisted(dsl_state, :aikido_resource) ||
        for %{path: path, schema: schema} <- own ++ slice_pseudo_specs do
          if schema in [nil, []], do: {path, [type: :map]}, else: {path, [type: schema]}
        end

    {:ok, Transformer.persist(dsl_state, :merged_schema, merged_schema)}
  end
end
