defmodule Aikido.Signal.Dsl do
  @moduledoc false
  @signal %Spark.Dsl.Section{
    name: :signal,
    schema: [
      type: [type: :string, required: true],
      source: [type: :string, default: "/aikido"]
    ],
    sections: [Aikido.Dsl.Schema.attribute_section()]
  }
  use Spark.Dsl.Extension, sections: [@signal]
end
