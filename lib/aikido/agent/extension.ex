defmodule Aikido.Agent.Extension do
  @moduledoc """
  Process-backed Ash agent resources with generic actions.

  Add `extensions: [Aikido.Agent.Extension]` to an Ash resource. Agent schema declarations become native
  resource attributes. `start` returns a reference containing the stable ID,
  current PID and resource. Signal actions accept that reference, an ID or PID,
  plus arguments inferred from their target's schema, and return a processing
  receipt. `inspect` and `list` explicitly read live state; `stop` confirms shutdown.
  `persistence :permanent` (the default) keeps saved state after stop;
  `persistence :temporary` deletes it. Both checkpoint while running for recovery.
  `delete` always removes the process and saved state, including by a stopped ID.

  Commands do not return state. A processing receipt acknowledges the signal
  callback, not completion of asynchronous effects or exactly-once delivery.
  """

  @slice %Spark.Dsl.Entity{
    name: :slice,
    target: Aikido.Agent.SliceMount,
    args: [:path, :module],
    identifier: :path,
    schema: [
      path: [type: :atom, required: true],
      module: [type: :module, required: true],
      options: [type: {:or, [:keyword_list, :map]}, default: []]
    ]
  }
  # Reuse Ash's attribute entities so types, constraints and options have exactly
  # the same syntax and validation as an ordinary resource attributes section.
  @schema %{Enum.find(Ash.Resource.Dsl.sections(), &(&1.name == :attributes)) | name: :schema}
  @route %Spark.Dsl.Entity{
    name: :route,
    target: Aikido.Agent.Route,
    args: [:type, :action],
    schema: [
      type: [type: :any, required: true],
      action: [type: :any, required: true],
      name: [
        type: :atom,
        doc: "Optional action name; inferred from the signal or target by default."
      ],
      public?: [
        type: :boolean,
        doc:
          "Expose a domain command; defaults to true for concrete signals and false for patterns."
      ],
      priority: [type: :integer, default: 0],
      match: [type: {:fun, 1}]
    ]
  }
  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    target: Aikido.Cron.AgentSchedule,
    args: [:cron, :signal_type],
    schema: [
      cron: [type: :string, required: true],
      signal_type: [type: :any, required: true],
      data: [type: :map, default: %{}],
      job_id: [type: :any],
      timezone: [type: :string]
    ]
  }
  @schedules %Spark.Dsl.Section{name: :schedules, entities: [@schedule]}
  @agent %Spark.Dsl.Section{
    name: :agent,
    schema: [
      name: [type: :string, required: true],
      description: [type: :string],
      instance: [
        type: :atom,
        default: Aikido.Default,
        doc: "Runtime supervisor; defaults to Aikido.Default."
      ],
      middleware: [type: {:list, :any}, default: []],
      persistence: [
        type: {:in, Aikido.Agent.Types.PersistenceMode.values()},
        default: :permanent,
        doc:
          "Snapshot retention after stop. :permanent retains saved state; :temporary deletes it. Both checkpoint while running."
      ],
      path: [type: :atom, default: :state]
    ],
    sections: [@schema],
    entities: [@slice, @route]
  }
  use Spark.Dsl.Extension,
    sections: [@agent, @schedules],
    transformers: [
      Aikido.Agent.Extension.Transformers.Build,
      Aikido.Agent.Extension.Transformers.WalkExtensions,
      Aikido.Agent.Extension.Transformers.ExpandRoutes,
      Aikido.Agent.Extension.Transformers.AddInitialization
    ],
    verifiers: [
      Aikido.Agent.Extension.Verifiers.Validate,
      Aikido.Agent.Extension.Verifiers.UniquePaths,
      Aikido.Agent.Extension.Verifiers.Composition
    ]
end
