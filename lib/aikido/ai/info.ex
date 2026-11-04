defmodule Aikido.AI.Info do
  @moduledoc "Native Spark introspection for resource-owned AI configuration."
  use Spark.InfoGenerator, extension: Aikido.AI.Extension, sections: [:ai]
end
