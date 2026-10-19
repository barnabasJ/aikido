defmodule Aikido.Ash.Slice do
  @moduledoc """
  Embedded Ash resource extension for agent slices.

  Use with `data_layer: :embedded`. Declare native generic actions on the slice
  resource, returning `Aikido.ActionResult`. Routed actions receive `state`
  (the current slice value) and typed payload arguments. The agent pipeline
  applies that returned state and executes the directives after the action.
  Slice actions are pure and must never perform side effects; return directives
  for all I/O, message delivery, process creation and scheduling.

  Mounting the slice automatically exposes its routed public actions on the
  agent's domain interface, using the Ash action names and payload contracts.
  Private actions and schedule-only actions remain internal.

  A slice is an embedded resource because its value lives inside an agent's
  state. Implementation modules use `Ash.Resource.Actions.Implementation`;
  they do not declare separate resources or duplicate the action contracts.
  """
  defmodule Route do
    @moduledoc false
    defstruct [
      :type,
      :action,
      :match,
      :static,
      :on_conflict,
      priority: 0,
      __spark_metadata__: nil
    ]
  end

  defmodule Schedule do
    @moduledoc false
    defstruct [:cron, :action, :tz, :signal, data: %{}, __spark_metadata__: nil]
  end

  @route %Spark.Dsl.Entity{
    name: :route,
    target: Route,
    args: [:type, :action],
    schema: [
      type: [type: :string, required: true],
      action: [type: :atom, required: true],
      priority: [type: :integer, default: 0],
      match: [type: {:fun, 1}],
      static: [type: :map],
      on_conflict: [type: {:in, [:replace]}]
    ]
  }
  @slice %Spark.Dsl.Section{
    name: :slice,
    sections: [
      Aikido.Dsl.Schema.attribute_section(),
      Aikido.Dsl.Schema.attribute_section(:config_schema)
    ],
    schema: Enum.find(Aikido.Dsl.Slice.sections(), &(&1.name == :slice)).schema,
    entities: [@route]
  }
  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    target: Schedule,
    args: [:cron, :action],
    schema: [
      cron: [type: :string, required: true],
      action: [type: :atom, required: true],
      data: [type: :map, default: %{}],
      tz: [type: :string],
      signal: [type: :string]
    ]
  }
  @schedules %Spark.Dsl.Section{name: :schedules, entities: [@schedule]}
  use Spark.Dsl.Extension,
    sections: [@slice, @schedules],
    transformers: [Aikido.Ash.Transformers.Slice]
end
