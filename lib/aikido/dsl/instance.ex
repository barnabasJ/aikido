defmodule Aikido.Dsl.Instance do
  @moduledoc """
  Spark DSL extension for `use Aikido` (the application instance
  supervisor).

  Defines a single host-owned section:

    * `instance do … end` — `otp_app`, `default_slices`.

  Spark validates and stores the configuration. Read it through
  `Aikido.Dsl.Instance.Info`. Supervision entry points come from the instance
  host; lifecycle, persistence and debugging use the shared runtime APIs.
  """

  @instance_section %Spark.Dsl.Section{
    name: :instance,
    describe: "Application instance configuration.",
    schema: [
      otp_app: [type: :atom, required: true, doc: "The otp_app for this Aikido instance."],
      default_slices: [type: :any, doc: "Override default slices; nil keeps framework defaults."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@instance_section]
end
