defmodule Aikido.Dsl.Agent do
  @moduledoc """
  Spark DSL extension for `Aikido.Agent`.

  Defines four host-owned sections:

    * `agent do … end` — agent identity (name, description, path, schema)
    * `slices do … end` — slice mounts at agent-declared paths
    * `signal_routes do … end` — `route` entries
    * `schedules do … end` — `schedule` entries

  The `slices do … end` section is the single source of truth for
  path-to-slice binding on the agent. Each `slice :path, Module` line
  mounts a slice at the agent-declared `:path`. The agent
  owns the binding so the same slice module can mount at different
  paths on different agents.

  Middleware lives at the top level on `use Aikido.Agent, middleware: […]`
  because order matters and a flat ordered list is the right shape.
  The `extensions: […]` keyword on `use Aikido.Agent` is reserved for
  modules that contribute a typed DSL section to the host agent (the
  Spark DSL section contribution mechanism, e.g. `react do … end`
  for `Aikido.Slices.AiReact`). Declare slice mounts in `slices`.
  """

  alias Aikido.Dsl.Agent.Route
  alias Aikido.Dsl.Agent.Schedule
  alias Aikido.Dsl.Agent.SliceMount

  @agent_section %Spark.Dsl.Section{
    name: :agent,
    describe: "Agent identity and base configuration.",
    sections: [Aikido.Dsl.Schema.attribute_section()],
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Agent name (letters, numbers, underscores)."
      ],
      description: [type: :string],
      path: [
        type: :atom,
        doc:
          "Atom slice key where the agent's user-domain state lives. " <>
            "Required when `schema:` is set; omit both for a pure composition agent."
      ]
    ]
  }

  @slice_mount %Spark.Dsl.Entity{
    name: :slice,
    describe: "Mounts a slice at an agent-declared path.",
    target: SliceMount,
    args: [:path, :module],
    schema: [
      path: [
        type: :atom,
        required: true,
        doc: "Atom slice key in agent.state where this slice's value lives."
      ],
      module: [
        type: :atom,
        required: true,
        doc: "Slice (`use Aikido.Slice`) module to mount."
      ],
      options: [
        type: {:or, [:keyword_list, :map]},
        default: [],
        doc:
          "Configuration map / keyword list to seed the slice with. Merged " <>
            "with values from any contributed-section block (e.g. `react do … end`)."
      ]
    ]
  }

  @slices_section %Spark.Dsl.Section{
    name: :slices,
    describe:
      "Slice mounts. Each `slice :path, Module` registers a slice " <>
        "at the agent-declared path. The same module may be mounted at multiple " <>
        "paths (`slice :slack_support, SlackSlice; slice :slack_sales, SlackSlice`); " <>
        "at signal-route dispatch the framework fans the action out, calling it once " <>
        "per matching mount with each mount's own slice state and `ctx.slice_config` " <>
        "(per-mount config visible to the action).",
    entities: [@slice_mount]
  }

  @route %Spark.Dsl.Entity{
    name: :route,
    describe: "Maps a signal type/pattern to an action target.",
    target: Route,
    args: [:type, :action],
    schema: [
      type: [type: :string, required: true],
      action: [type: :any, required: true],
      priority: [type: :integer, default: 0],
      match: [type: {:fun, 1}]
    ]
  }

  @signal_routes_section %Spark.Dsl.Section{
    name: :signal_routes,
    describe: "Compile-time signal route table.",
    entities: [@route]
  }

  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    describe: "Declarative cron schedule.",
    target: Schedule,
    args: [:cron, :signal_type],
    schema: [
      cron: [type: :string, required: true],
      signal_type: [type: :string, required: true],
      data: [type: :map, default: %{}],
      job_id: [type: :any],
      timezone: [type: :string]
    ]
  }

  @schedules_section %Spark.Dsl.Section{
    name: :schedules,
    describe: "Declarative agent-level cron schedules.",
    entities: [@schedule]
  }

  use Spark.Dsl.Extension,
    sections: [
      @agent_section,
      @slices_section,
      @signal_routes_section,
      @schedules_section
    ],
    transformers: [
      Aikido.Dsl.Transformers.Attributes,
      Aikido.Dsl.Agent.Transformers.WalkExtensions,
      Aikido.Dsl.Agent.Transformers.ExpandRoutes,
      Aikido.Dsl.Agent.Transformers.AddInitialization
    ],
    verifiers: [
      Aikido.Dsl.Agent.Verifiers.PathSchemaPair,
      Aikido.Dsl.Agent.Verifiers.UniquePaths,
      Aikido.Dsl.Agent.Verifiers.Composition
    ]
end
