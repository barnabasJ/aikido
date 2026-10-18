defmodule Aikido.Dsl.Instance.Info do
  @moduledoc """
  Introspection surface for `use Aikido` (Aikido instance) modules.

  Reads the `instance do … end` section options from the instance's
  Spark `dsl_state`.
  """

  use Spark.InfoGenerator, extension: Aikido.Dsl.Instance, sections: [:instance]
end
