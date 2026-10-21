defmodule Aikido.Cron.AgentSchedules do
  @moduledoc "Expands agent cron declarations into signal schedules."
  @type schedule_spec :: %{
          cron_expression: String.t(),
          job_id: term(),
          signal_type: String.t(),
          timezone: String.t(),
          data: map()
        }

  def expand_schedules(schedules, agent_name) do
    Enum.map(schedules, fn schedule ->
      %{
        cron_expression: schedule.cron,
        job_id:
          {:agent_schedule, agent_name,
           if(is_nil(schedule.job_id), do: schedule.signal_type, else: schedule.job_id)},
        signal_type: schedule.signal_type,
        timezone: schedule.timezone || "Etc/UTC",
        data: schedule.data
      }
    end)
  end
end
