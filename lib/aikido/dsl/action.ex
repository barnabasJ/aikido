defmodule Aikido.Dsl.Action do
  @moduledoc """
  Spark DSL extension for `Aikido.Action`.

  Defines a single host-owned section:

    * `action do … end` — action identity (`name`, `description`,
      `category`, `tags`, `vsn`, `path`, `compensation`, `schema`,
      `output_schema`).

  The `GenerateAccessors` transformer emits the runtime delegates
  (`validate_params/1`, `validate_output/1`) and lifecycle-hook
  defaults; introspection (name/description/path/schema/etc.) lives
  in `Aikido.Dsl.Action.Info`.
  """

  @action_section %Spark.Dsl.Section{
    name: :action,
    describe: "Action identity and metadata.",
    sections: [
      Aikido.Dsl.Schema.attribute_section(),
      Aikido.Dsl.Schema.attribute_section(:output_schema)
    ],
    schema: [
      name: [
        type: {:custom, Aikido.Util, :validate_name, []},
        required: true,
        doc: "Action name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      category: [type: :string],
      tags: [type: {:list, :string}, default: []],
      vsn: [type: :string],
      path: [
        type: :atom,
        doc:
          "Optional escape-valve mount path. Most actions should omit this — " <>
            "the framework resolves the action's slice path from the slice " <>
            "whose `signal_routes` route to it. Only declare `path:` for " <>
            "ad-hoc actions that aren't owned by a slice (e.g. test fixtures, " <>
            "in-turn topology actions on the agent's own signal_routes)."
      ],
      compensation: [
        type: :any,
        default: %{enabled: false, max_retries: 1, timeout: 5000},
        doc: "Compensation declaration; see `Aikido.Action.Schema`."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@action_section],
    transformers: [
      Aikido.Dsl.Transformers.CompileSchemas,
      Aikido.Dsl.Action.Transformers.GenerateAccessors
    ]
end
