defmodule Aikido.Cron.Declarations do
  @moduledoc "Compiles agent and mounted-slice cron declarations into scheduled signals and routes."
  alias Aikido.Slice.Instance

  @type schedule_spec :: %{
          required(:cron_expression) => String.t(),
          required(:job_id) => term(),
          required(:signal_type) => String.t(),
          required(:timezone) => String.t(),
          required(:data) => map(),
          optional(:action) => {module(), atom()}
        }

  @doc "Compile recurring signals declared directly on an agent."
  @spec agent_schedules([struct()], String.t()) :: [schedule_spec()]
  def agent_schedules(schedules, agent_name) do
    Enum.map(schedules, fn schedule ->
      %{
        cron_expression: schedule.cron,
        job_id:
          {:agent_schedule, agent_name,
           if(is_nil(schedule.job_id), do: schedule.signal_type, else: schedule.job_id)},
        signal_type: schedule.signal_type,
        timezone: normalize_timezone(schedule.timezone),
        data: schedule.data
      }
    end)
  end

  @doc "Compile recurring actions with identities scoped to their slice mount."
  @spec slice_schedules(Instance.t()) :: [schedule_spec()]
  def slice_schedules(%Instance{} = instance) do
    instance.module
    |> Aikido.Slice.Info.schedules()
    |> Enum.map(&expand_slice_schedule(&1, instance.path))
  end

  @doc "Build routes for scheduled slice actions, sharing identical targets."
  def slice_routes(%Instance{} = instance) do
    instance
    |> slice_schedules()
    |> Enum.map(&{&1.signal_type, &1.action, [priority: -20]})
    |> Enum.uniq()
  end

  defp expand_slice_schedule({cron, action}, path),
    do: expand_slice_schedule({cron, action, []}, path)

  defp expand_slice_schedule({cron, {_resource, action_name} = action, options}, path) do
    timezone = normalize_timezone(Keyword.get(options, :timezone))
    signal = Keyword.get(options, :signal_type)
    signal_type = if signal, do: "#{path}.#{signal}", else: "#{path}.__schedule__.#{action_name}"
    data = Keyword.get(options, :data, %{})

    %{
      cron_expression: cron,
      action: action,
      job_id: {:slice_schedule, path, {action, cron, timezone, signal_type, data}},
      signal_type: signal_type,
      timezone: timezone,
      data: data
    }
  end

  defp normalize_timezone(timezone) when timezone in [nil, ""], do: "Etc/UTC"
  defp normalize_timezone(timezone), do: timezone
end
