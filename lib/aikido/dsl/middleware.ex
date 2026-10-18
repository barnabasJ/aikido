defmodule Aikido.Dsl.Middleware do
  @moduledoc """
  Spark DSL extension for `Aikido.Middleware`.

  Defines a single, minimal `middleware do … end` section for declaring
  the middleware's optional `:description` and `:schema` (Spark.Options
  schema validating per-registration `opts`). Most middleware modules
  do not need any configurable shape beyond their callback; the section
  is optional.
  """

  @middleware_section %Spark.Dsl.Section{
    name: :middleware,
    describe: "Middleware metadata.",
    schema: [
      description: [type: :string],
      schema: [
        type: :keyword_list,
        default: [],
        doc: "Spark.Options schema validating per-registration opts."
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@middleware_section]
end
