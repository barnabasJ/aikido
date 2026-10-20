defmodule Aikido.Signal.Info do
  @moduledoc "Introspection for Spark signal definitions."
  use Spark.InfoGenerator, extension: Aikido.Signal.Dsl, sections: [:signal]

  @doc "The native Ash attributes defining this signal's payload."
  def schema(module), do: Spark.Dsl.Extension.get_entities(module, [:signal, :schema])
end
