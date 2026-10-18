defmodule Aikido.Dsl.Sensor.Info do
  @moduledoc """
  Introspection surface for `use Aikido.Sensor` modules.

  Each accessor takes the sensor module and reads a field from the
  sensor's Spark `dsl_state`. Replaces the per-sensor hand-rolled
  accessor surface that the `GenerateAccessors` transformer used to
  emit on the sensor module.
  """

  use Spark.InfoGenerator, extension: Aikido.Dsl.Sensor, sections: [:sensor]

  alias Spark.Dsl.Extension

  @section [:sensor]

  @doc "Returns the Ash field contract for sensor configuration."
  @spec schema(module()) :: term() | nil
  def schema(module), do: Extension.get_opt(module, @section, :schema)
end
