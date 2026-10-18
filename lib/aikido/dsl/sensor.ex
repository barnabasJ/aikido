defmodule Aikido.Dsl.Sensor do
  @moduledoc """
  Spark DSL extension for `Aikido.Sensor`.

  Defines a single host-owned section:

    * `sensor do … end` — sensor identity (`name`, `description`,
      `category`, `tags`, `vsn`, `schema`).

  The `GenerateAccessors` transformer emits the default `terminate/2`
  callback and its `defoverridable`. Sensor introspection lives in
  `Aikido.Dsl.Sensor.Info`.
  """

  @sensor_section %Spark.Dsl.Section{
    name: :sensor,
    describe: "Sensor identity and metadata.",
    sections: [Aikido.Dsl.Schema.attribute_section()],
    schema: [
      name: [
        type: {:custom, Aikido.Util, :validate_name, []},
        required: true,
        doc: "Sensor name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@sensor_section],
    transformers: [
      Aikido.Dsl.Transformers.Attributes,
      Aikido.Dsl.Sensor.Transformers.GenerateAccessors
    ]
end
