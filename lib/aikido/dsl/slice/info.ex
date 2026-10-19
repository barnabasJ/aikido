defmodule Aikido.Dsl.Slice.Info do
  @moduledoc """
  Introspection surface for `use Aikido.Slice` modules.

  Each accessor takes the slice module and reads a field from the slice's
  Spark `dsl_state`.

  `signal_routes/1` and `schedules/1` return route and schedule tuples;
  `capabilities/1` returns capability names and `requires/1` returns
  requirement tuples. `actions/1` derives the unique action targets from
  the route table on each call.
  """

  use Spark.InfoGenerator, extension: Aikido.Dsl.Slice, sections: [:slice]

  alias Spark.Dsl.Extension

  @section [:slice]

  @doc "Returns the Ash field contract for slice state."
  @spec schema(module()) :: term() | nil
  def schema(module) do
    if native_slice?(module), do: module, else: Extension.get_opt(module, @section, :schema)
  end

  @doc "Returns the Ash field contract for per-agent configuration."
  @spec config_schema(module()) :: term() | nil
  def config_schema(module), do: Extension.get_opt(module, @section, :config_schema)

  @doc "Returns the signal routes for this slice as `{type, action[, opts]}` tuples."
  @spec signal_routes(module()) :: [tuple()]
  def signal_routes(module) do
    if native_slice?(module) do
      routes = Extension.get_entities(module, [:slice])

      scheduled =
        module
        |> Extension.get_entities([:schedules])
        |> Enum.reject(fn entry -> Enum.any?(routes, &(&1.action == entry.action)) end)
        |> Enum.map(fn entry ->
          %Aikido.Ash.Slice.Route{
            type:
              "aikido.ash.schedule.#{Extension.get_opt(module, [:slice], :name)}.#{entry.action}",
            action: entry.action
          }
        end)

      Enum.map(routes ++ scheduled, &route_tuple(%{&1 | action: {module, &1.action}}))
    else
      module
      |> Extension.get_entities([:signal_routes])
      |> Enum.map(&route_tuple/1)
    end
  end

  @doc "Returns the schedules for this slice as `{cron, action[, opts]}` tuples."
  @spec schedules(module()) :: [tuple()]
  def schedules(module) do
    module
    |> Extension.get_entities([:schedules])
    |> Enum.map(fn entry ->
      entry = if native_slice?(module), do: %{entry | action: {module, entry.action}}, else: entry
      schedule_tuple(entry)
    end)
  end

  @doc "Returns the capabilities provided by this slice."
  @spec capabilities(module()) :: [atom()]
  def capabilities(module) do
    module
    |> Extension.get_entities([:capabilities])
    |> Enum.map(& &1.name)
  end

  @doc "Returns the requirements for this slice as `{kind, name}` tuples."
  @spec requires(module()) :: [{atom(), atom() | String.t()}]
  def requires(module) do
    module
    |> Extension.get_entities([:requires])
    |> Enum.map(fn %{kind: kind, name: name} -> {kind, name} end)
  end

  @doc """
  Returns the deduplicated list of action modules referenced by this
  slice's signal routes.
  """
  @spec actions(module()) :: [module()]
  def actions(module) do
    if native_slice?(module) do
      module |> signal_routes() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    else
      module
      |> Extension.get_entities([:signal_routes])
      |> Enum.map(& &1.action)
      |> Enum.uniq()
    end
  end

  defp native_slice?(module),
    do: Spark.Dsl.is?(module, Ash.Resource) && Aikido.Ash.Slice in Spark.extensions(module)

  defp route_tuple(entry) do
    %{type: type, action: action, match: match} = entry
    opts = build_route_opts(entry)

    cond do
      is_function(match, 1) -> {type, match, action}
      opts == [] -> {type, action}
      true -> {type, action, opts}
    end
  end

  defp build_route_opts(entry) do
    []
    |> maybe_put(:priority, entry.priority, fn p -> is_integer(p) and p != 0 end)
    |> maybe_put(:on_conflict, entry.on_conflict, &(not is_nil(&1)))
    |> maybe_put(:static, entry.static, &(not is_nil(&1)))
    |> Enum.reverse()
  end

  defp schedule_tuple(entry) do
    opts = build_schedule_opts(entry)
    if opts == [], do: {entry.cron, entry.action}, else: {entry.cron, entry.action, opts}
  end

  defp build_schedule_opts(entry) do
    []
    |> maybe_put(:tz, entry.tz, &(not is_nil(&1)))
    |> maybe_put(:signal, entry.signal, &(not is_nil(&1)))
    |> maybe_put(:data, entry.data, &(is_map(&1) and map_size(&1) > 0))
    |> Enum.reverse()
  end

  defp maybe_put(opts, key, value, predicate) do
    if predicate.(value), do: [{key, value} | opts], else: opts
  end
end
