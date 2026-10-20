defmodule Aikido.Dsl.Slice.Info do
  @moduledoc "Native slice configuration, routes and schedules."
  use Spark.InfoGenerator, extension: Aikido.Ash.Slice, sections: [:slice]
  alias Spark.Dsl.Extension

  def schema(resource), do: resource
  def config_schema(resource), do: Extension.get_entities(resource, [:slice, :config_schema])

  def signal_routes(resource) do
    resource
    |> Extension.get_entities([:slice])
    |> Enum.map(fn route ->
      target = target(resource, route.action)

      cond do
        is_function(route.match, 1) ->
          {route.type, route.match, target,
           if(route.priority == 0, do: -10, else: route.priority)}

        route.priority != 0 ->
          {route.type, target, [priority: route.priority]}

        true ->
          {route.type, target}
      end
    end)
  end

  def schedules(resource) do
    resource
    |> Extension.get_entities([:schedules])
    |> Enum.map(fn schedule ->
      options = [data: schedule.data]
      options = if schedule.tz, do: Keyword.put(options, :tz, schedule.tz), else: options

      options =
        if schedule.signal, do: Keyword.put(options, :signal, schedule.signal), else: options

      {schedule.cron, target(resource, schedule.action), options}
    end)
  end

  def actions(resource) do
    routes = Enum.map(Extension.get_entities(resource, [:slice]), &target(resource, &1.action))

    schedules =
      Enum.map(Extension.get_entities(resource, [:schedules]), &target(resource, &1.action))

    Enum.uniq(routes ++ schedules)
  end

  def target(resource, action) when is_atom(action), do: {resource, action}
  def target(_resource, {resource, action}), do: {resource, action}
end
