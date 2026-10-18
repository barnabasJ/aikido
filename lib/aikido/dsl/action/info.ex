defmodule Aikido.Dsl.Action.Info do
  @moduledoc """
  Introspection surface for `use Aikido.Action` modules.

  Each accessor takes the action module and reads a field from the
  action's Spark `dsl_state`. Replaces the per-action hand-rolled
  accessor surface that the `GenerateAccessors` transformer used to
  emit on the action module.
  """

  use Spark.InfoGenerator, extension: Aikido.Dsl.Action, sections: [:action]

  alias Spark.Dsl.Extension

  @section [:action]

  @doc "Returns the input schema of the Action."
  @spec schema(module()) :: term()
  def schema(module), do: Extension.get_opt(module, @section, :schema, [])

  @doc "Returns the output schema of the Action."
  @spec output_schema(module()) :: term()
  def output_schema(module), do: Extension.get_opt(module, @section, :output_schema, [])

  @doc """
  Returns the Action metadata as a JSON-serializable map.
  """
  @spec to_json(module()) :: map()
  def to_json(module) do
    %{
      name: Map.get(action_options(module), :name),
      description: Map.get(action_options(module), :description),
      category: Map.get(action_options(module), :category),
      tags: Map.get(action_options(module), :tags),
      vsn: Map.get(action_options(module), :vsn),
      compensation: Map.get(action_options(module), :compensation),
      schema: schema(module),
      output_schema: output_schema(module)
    }
  end
end
