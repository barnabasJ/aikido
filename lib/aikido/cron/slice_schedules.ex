defmodule Aikido.Cron.SliceSchedules do
  @moduledoc """
  Utilities for expanding and managing slice schedules.

  This module handles:
  - Expanding schedule declarations from slice manifests
  - Generating unique job IDs namespaced to slice mounts
  - Generating signal types for schedule triggers

  ## Schedule Formats

  Schedules can be specified in several formats:

  - `{"*/5 * * * *", {Resource, :action}}` - Simple schedule with default timezone
  - `{"*/5 * * * *", {Resource, :action}, tz: "America/New_York"}` - With timezone
  - `{"*/5 * * * *", {Resource, :action}, signal: "custom.signal"}` - Custom signal type

  ## Signal Type Generation

  By default, schedule signal types are auto-generated as:
  `"{path}.__schedule__.{action_name}"`

  ## Job ID Namespacing

  Job IDs are namespaced as tuples to ensure uniqueness across slice mounts:
  `{:slice_schedule, mount_path, {target, cron, timezone, signal_type, data}}`.
  Each distinct normalized declaration has its own job; identical generated
  routes are shared so each occurrence invokes its target once.
  """

  alias Aikido.Slice.Info, as: SliceInfo
  alias Aikido.Slice.Instance

  @schedule_route_priority -20

  @typedoc """
  Represents an expanded schedule specification.
  """
  @type schedule_spec :: %{
          cron_expression: String.t(),
          action: {module(), atom()},
          job_id:
            {:slice_schedule, atom(),
             {{module(), atom()}, String.t(), String.t(), String.t(), map()}},
          signal_type: String.t(),
          timezone: String.t(),
          data: map()
        }

  @doc """
  Expands schedules from a slice instance.

  Takes a slice instance and returns expanded schedule specifications
  with unique job IDs and auto-generated signal types.
  """
  @spec expand_schedules(Instance.t()) :: [schedule_spec()]
  def expand_schedules(%Instance{} = instance) do
    schedules = SliceInfo.schedules(instance.module)
    mount_path = instance.path
    prefix = Atom.to_string(mount_path)

    Enum.map(schedules, fn schedule ->
      expand_schedule(schedule, mount_path, prefix)
    end)
  end

  @doc """
  Generates routes for schedule signal types.

  Schedule signal types need routes so they can be dispatched through
  the normal signal routing pipeline. These routes have low priority
  to avoid conflicting with explicit routes.

  Returns a list of route tuples suitable for the agent's route table.
  """
  @spec schedule_routes(Instance.t()) :: [{String.t(), {module(), atom()}, keyword()}]
  def schedule_routes(%Instance{} = instance) do
    instance
    |> expand_schedules()
    |> Enum.map(fn spec ->
      {spec.signal_type, spec.action, [priority: @schedule_route_priority]}
    end)
    |> Enum.uniq()
  end

  defp expand_schedule({cron_expr, action}, mount_path, prefix) do
    expand_schedule({cron_expr, action, []}, mount_path, prefix)
  end

  defp expand_schedule({cron_expr, action, opts}, mount_path, prefix)
       when is_list(opts) do
    timezone = Keyword.get(opts, :tz)
    timezone = if timezone in [nil, ""], do: "Etc/UTC", else: timezone
    custom_signal = Keyword.get(opts, :signal)

    signal_type =
      if custom_signal do
        "#{prefix}.#{custom_signal}"
      else
        generate_signal_type(prefix, action)
      end

    data = Keyword.get(opts, :data, %{})
    job_id = {:slice_schedule, mount_path, {action, cron_expr, timezone, signal_type, data}}

    %{
      cron_expression: cron_expr,
      action: action,
      job_id: job_id,
      signal_type: signal_type,
      timezone: timezone,
      data: data
    }
  end

  defp generate_signal_type(prefix, {_resource, action}),
    do: "#{prefix}.__schedule__.#{action}"
end
