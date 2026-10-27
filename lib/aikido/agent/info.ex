defmodule Aikido.Agent.Info do
  @moduledoc """
  Introspection for native Ash agent resources.

  Reads declared agent options and compiled slice mounts, action ownership,
  middleware, routes and schedules from Spark metadata.
  """

  use Spark.InfoGenerator, extension: Aikido.Agent.Extension, sections: [:agent]

  alias Spark.Dsl.Extension

  @doc "Returns the resource attributes belonging to the agent's own state."
  @spec state_fields(module()) :: [atom()]
  def state_fields(resource), do: Extension.get_persisted(resource, :aikido_state_fields, [])

  @doc "Returns the compiled team configuration, or nil for a resource without a team."
  @spec team_config(module() | nil) :: map() | nil
  def team_config(resource) do
    if Spark.Dsl.is?(resource, Ash.Resource),
      do: Extension.get_persisted(resource, :aikido_team_config)
  end

  @doc "Whether the agent resource has AI configuration."
  @spec ai?(module()) :: boolean()
  def ai?(resource), do: Extension.get_persisted(resource, :aikido_ai?, false)

  @doc "Returns the middleware modules attached to this agent."
  @spec middleware(module()) :: [module() | {module(), map()}]
  def middleware(module), do: Extension.get_persisted(module, :middleware_list, [])

  @doc "Returns the deduplicated list of slice modules attached to this agent."
  @spec slices(module()) :: [module()]
  def slices(module) do
    module
    |> slice_instances()
    |> Enum.map(& &1.module)
    |> Enum.uniq()
  end

  @doc "Returns the list of slice instances attached to this agent."
  @spec slice_instances(module()) :: [Aikido.Slice.Instance.t()]
  def slice_instances(module),
    do: Extension.get_persisted(module, :slice_instances, [])

  @doc "Returns the slice paths owned by attached slices."
  @spec slice_paths(module()) :: [atom()]
  def slice_paths(module),
    do: Extension.get_persisted(module, :slice_paths, [])

  @doc "Returns the expanded and validated routes for this agent."
  @spec routes(module()) :: [{String.t(), {module(), atom()}, integer()}]
  def routes(module),
    do: Extension.get_persisted(module, :validated_routes, [])

  @doc "Returns the expanded slice and agent schedules."
  @spec schedules(module()) :: [Aikido.Cron.Declarations.schedule_spec()]
  def schedules(module) do
    Extension.get_persisted(module, :expanded_slice_schedules, []) ++
      Extension.get_persisted(module, :expanded_agent_schedules, [])
  end

  @doc "Returns the agent's expanded signal routes."
  @spec signal_routes(module()) :: list()
  def signal_routes(module),
    do: Extension.get_persisted(module, :expanded_signal_routes, [])

  @doc """
  Returns the compile-time `{resource, action} => [mount_path, …]` map used by
  AgentServer to fan an action out across every mount that owns it.

  Multi-instance mounts of the same slice produce multi-element lists;
  single-mount actions are one-element lists; agent-level `route`
  declarations contribute the agent's own path. Actions not owned by any
  declared route are absent from the map and use the agent's own path.
  """
  @spec slice_paths_for_action(module()) :: %{{module(), atom()} => [atom()]}
  def slice_paths_for_action(module),
    do: Extension.get_persisted(module, :slice_paths_for_action, %{})

  @doc """
  Returns the compile-time `mount_path => config` map exposed to actions as
  `ctx.slice_config` during fan-out. Each mount has its own configuration.
  """
  @spec mount_config_map(module()) :: %{atom() => map()}
  def mount_config_map(module),
    do: Extension.get_persisted(module, :mount_config_map, %{})
end
