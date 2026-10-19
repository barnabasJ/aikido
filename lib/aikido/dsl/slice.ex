defmodule Aikido.Dsl.Slice do
  @moduledoc """
  Spark DSL extension for `Aikido.Slice`.

  Defines three host-owned sections:

    * `slice do … end` — slice identity (`name`, `path`, `description`,
      `otp_app`, `schema`, `config_schema`).
    * `signal_routes do … end` — `route "type", Action, opts` entries.
    * `schedules do … end` — `schedule "cron", Action, %{data}` entries.

  Introspection happens through `Aikido.Dsl.Slice.Info`, which reads each
  field (and the derived `actions/1`) from the slice's Spark
  `dsl_state`.
  """

  alias Aikido.Slice.RouteEntry
  alias Aikido.Slice.ScheduleEntry

  @slice_section %Spark.Dsl.Section{
    name: :slice,
    describe: "Slice identity and base configuration.",
    sections: [
      Aikido.Dsl.Schema.attribute_section(),
      Aikido.Dsl.Schema.attribute_section(:config_schema)
    ],
    schema: [
      name: [
        type: {:custom, Aikido.Slice, :validate_slice_name, []},
        required: true,
        doc: "Slice name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      otp_app: [type: :atom],
      state_transform: [type: :mfa],
      config_transform: [type: :mfa]
    ]
  }

  @route %Spark.Dsl.Entity{
    name: :route,
    describe: "Maps a signal type/pattern to an action target.",
    target: RouteEntry,
    args: [:type, :action],
    schema: [
      type: [type: :string, required: true],
      action: [type: :any, required: true],
      priority: [type: :integer, default: 0],
      match: [type: {:fun, 1}],
      static: [type: :map],
      on_conflict: [type: {:in, [:replace]}]
    ]
  }

  @signal_routes_section %Spark.Dsl.Section{
    name: :signal_routes,
    describe: "Compile-time signal routes contributed by this slice.",
    entities: [@route]
  }

  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    describe: "Declarative cron schedule contributed by this slice.",
    target: ScheduleEntry,
    args: [:cron, :action],
    schema: [
      cron: [type: :string, required: true],
      action: [type: :any, required: true],
      data: [type: :map, default: %{}],
      tz: [type: :string, doc: "IANA timezone for cron evaluation."],
      signal: [
        type: :string,
        doc: "Custom suffix for the schedule's signal type."
      ]
    ]
  }

  @schedules_section %Spark.Dsl.Section{
    name: :schedules,
    describe: "Cron schedules contributed by this slice.",
    entities: [@schedule]
  }

  use Spark.Dsl.Extension,
    sections: [
      @slice_section,
      @signal_routes_section,
      @schedules_section
    ],
    transformers: [Aikido.Dsl.Transformers.Attributes],
    verifiers: [Aikido.Dsl.Slice.Verifiers.HasSchemaAndRoutes]
end
