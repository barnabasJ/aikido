defmodule Aikido.Agent.Schedules do
  @moduledoc "Expands agent cron declarations into signal schedules."
  @type schedule_spec :: %{
          cron_expression: String.t(),
          action: nil,
          job_id: term(),
          signal_type: String.t(),
          timezone: String.t(),
          data: map()
        }

  def expand_schedules(schedules, agent_name) do
    Enum.map(schedules, fn schedule ->
      %{
        cron_expression: schedule.cron,
        action: nil,
        job_id: {:agent_schedule, agent_name, schedule.job_id || schedule.signal_type},
        signal_type: schedule.signal_type,
        timezone: schedule.timezone || "Etc/UTC",
        data: schedule.data
      }
    end)
  end
end
