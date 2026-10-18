defmodule Aikido.Dsl.Slice do
  @moduledoc """
  Spark DSL extension for `Aikido.Slice`.

  Defines six host-owned sections:

    * `slice do … end` — slice identity (`name`, `path`, `description`,
      `category`, `vsn`, `otp_app`, `schema`, `config_schema`, `tags`).
    * `signal_routes do … end` — `route "type", Action, opts` entries.
    * `subscriptions do … end` — `subscription Sensor, %{config}` entries.
    * `schedules do … end` — `schedule "cron", Action, %{data}` entries.
    * `capabilities do … end` — `capability :name` entries.
    * `requires do … end` — `requires :kind, :name` entries.

  Introspection happens through `Aikido.Dsl.Slice.Info`, which reads each
  field (and the derived `actions/1`) from the slice's Spark
  `dsl_state`.
  """

  alias Aikido.Slice.CapabilityEntry
  alias Aikido.Slice.RequiresEntry
  alias Aikido.Slice.RouteEntry
  alias Aikido.Slice.ScheduleEntry
  alias Aikido.Slice.SubscriptionEntry

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
      category: [type: :string],
      vsn: [type: :string],
      otp_app: [type: :atom],
      state_transform: [type: :mfa],
      config_transform: [type: :mfa],
      tags: [type: {:list, :string}, default: []]
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

  @subscription %Spark.Dsl.Entity{
    name: :subscription,
    describe: "Sensor subscription declared by this slice.",
    target: SubscriptionEntry,
    args: [:sensor, :config],
    schema: [
      sensor: [type: :atom, required: true],
      config: [type: :map, default: %{}]
    ]
  }

  @subscriptions_section %Spark.Dsl.Section{
    name: :subscriptions,
    describe: "Sensor subscriptions contributed by this slice.",
    entities: [@subscription]
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

  @capability %Spark.Dsl.Entity{
    name: :capability,
    describe: "Capability provided by this slice.",
    target: CapabilityEntry,
    args: [:name],
    schema: [name: [type: :atom, required: true]]
  }

  @capabilities_section %Spark.Dsl.Section{
    name: :capabilities,
    describe: "Capabilities advertised by this slice.",
    entities: [@capability]
  }

  @requires_entity %Spark.Dsl.Entity{
    name: :requires,
    describe: "Required dependency (config / app / plugin / slice).",
    target: RequiresEntry,
    args: [:kind, :name],
    schema: [
      kind: [type: {:in, [:config, :app, :plugin, :slice]}, required: true],
      name: [type: {:or, [:atom, :string]}, required: true]
    ]
  }

  @requires_section %Spark.Dsl.Section{
    name: :requires,
    describe: "Dependencies required by this slice.",
    entities: [@requires_entity]
  }

  use Spark.Dsl.Extension,
    sections: [
      @slice_section,
      @signal_routes_section,
      @subscriptions_section,
      @schedules_section,
      @capabilities_section,
      @requires_section
    ],
    transformers: [Aikido.Dsl.Transformers.Attributes],
    verifiers: [Aikido.Dsl.Slice.Verifiers.HasSchemaAndRoutes]
end
