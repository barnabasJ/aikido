defmodule Aikido.Agent.Extension.Transformers.ExpandRoutes do
  @moduledoc "Compiles native action routes and cron signal schedules for AgentServer."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Aikido.Agent.Extension.Transformers.WalkExtensions), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    instances = Transformer.get_persisted(dsl, :slice_instances, [])

    {:ok,
     dsl
     |> persist_own_routes()
     |> persist_slice_routes(instances)
     |> persist_schedules(instances)
     |> Transformer.persist(:mount_config_map, Map.new(instances, &{&1.path, &1.config}))}
  end

  defp persist_slice_routes(dsl, instances) do
    routes =
      Enum.flat_map(instances, &Aikido.Slice.Info.signal_routes(&1.module)) ++
        Enum.flat_map(instances, &Aikido.Cron.SliceSchedules.schedule_routes/1)

    routes =
      routes
      |> Enum.map(fn
        {type, match, target, priority} when is_function(match, 1) ->
          {type, match, target, priority}

        {type, target} ->
          {type, target, -10}

        {type, target, options} when is_list(options) ->
          {type, target, Keyword.get(options, :priority, -10)}

        {type, target, priority} when is_integer(priority) ->
          {type, target, priority}
      end)
      |> Enum.uniq()

    Transformer.persist(dsl, :validated_routes, routes)
  end

  defp persist_own_routes(dsl) do
    own_routes =
      Enum.map(Transformer.get_persisted(dsl, :aikido_agent_routes, []), fn route ->
        if is_function(route.match, 1),
          do: {route.type, route.match, route.action, route.priority},
          else: {route.type, route.action, route.priority}
      end)

    Transformer.persist(dsl, :expanded_signal_routes, own_routes)
  end

  defp persist_schedules(dsl, instances) do
    schedules =
      dsl
      |> Transformer.get_entities([:schedules])
      |> Aikido.Cron.AgentSchedules.expand_schedules(Transformer.get_option(dsl, [:agent], :name))

    dsl
    |> Transformer.persist(
      :expanded_slice_schedules,
      Enum.flat_map(instances, &Aikido.Cron.SliceSchedules.expand_schedules/1)
    )
    |> Transformer.persist(:expanded_agent_schedules, schedules)
  end
end
