defmodule Aikido.Dsl.Middleware.Info do
  @moduledoc """
  Introspection surface for `use Aikido.Middleware` modules.

  Reads the optional `middleware do … end` section options from the
  middleware's Spark `dsl_state`.
  """

  use Spark.InfoGenerator, extension: Aikido.Dsl.Middleware, sections: [:middleware]

  alias Spark.Dsl.Extension

  @section [:middleware]

  @doc "Returns the Spark.Options schema validating per-registration opts."
  @spec schema(module()) :: keyword()
  def schema(module), do: Extension.get_opt(module, @section, :schema, [])
end
