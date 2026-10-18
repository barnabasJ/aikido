defmodule Aikido.Actions.Scheduling do
  @moduledoc """
  Base actions for scheduling delayed signals and timeouts.

  These actions wrap the `Schedule` directive for common timing patterns.

  ## Usage

      use Aikido.Agent

      agent do
        name "timed_worker"
      end

      signal_routes do
        route "work.start", MyStartAction       # Might schedule a timeout
        route "work.timeout", MyTimeoutHandler
      end
  """

  defmodule ScheduleSignal do
    @moduledoc """
    Schedule a signal to be delivered after a delay.

    The signal will be delivered to the agent's own mailbox after
    the specified delay.

    ## Schema

    - `delay_ms` - Delay in milliseconds (required)
    - `signal_type` - Signal type to schedule (required)
    - `payload` - Signal payload data (default: %{})
    - `source` - Signal source path (default: "/scheduler")

    ## Example

        # Schedule a completion check
        {Aikido.Actions.Scheduling.ScheduleSignal, %{
          delay_ms: 5000,
          signal_type: "work.check",
          payload: %{attempt: 1}
        }}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{
                name: "schedule_signal",
                description: "Schedule a signal to be delivered after a delay"
              }}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        argument(:delay_ms, :integer,
          description: "Delay in milliseconds",
          allow_nil?: false,
          constraints: [min: 0]
        )

        argument(:signal_type, :string, description: "Signal type to schedule", allow_nil?: false)
        argument(:payload, :map, description: "Signal payload data", default: %{})
        argument(:source, :string, description: "Signal source path", default: "/scheduler")
        description("Schedule a signal to be delivered after a delay")
        run(Aikido.Actions.Scheduling.ScheduleSignal.Implementation)
      end
    end
  end

  defmodule ScheduleTimeout do
    @moduledoc """
    Schedule a timeout signal for deadline handling.

    Convenience wrapper that schedules a standard timeout signal
    that can be handled to fail the agent or take corrective action.

    ## Schema

    - `timeout_ms` - Timeout duration in milliseconds (required)
    - `timeout_id` - Identifier for this timeout (default: :default)
    - `signal_type` - Signal type for timeout (default: "agent.timeout")

    ## Example

        # Set a 30 second deadline
        {Aikido.Actions.Scheduling.ScheduleTimeout, %{
          timeout_ms: 30_000,
          timeout_id: :work_deadline
        }}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{
                name: "schedule_timeout",
                description: "Schedule a timeout signal for deadline handling"
              }}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        argument(:timeout_ms, :integer,
          description: "Timeout in milliseconds",
          allow_nil?: false,
          constraints: [min: 0]
        )

        argument(:timeout_id, :term,
          description: "Identifier for this timeout",
          default: :default
        )

        argument(:signal_type, :string,
          description: "Timeout signal type",
          default: "agent.timeout"
        )

        description("Schedule a timeout signal for deadline handling")
        run(Aikido.Actions.Scheduling.ScheduleTimeout.Implementation)
      end
    end
  end

  defmodule ScheduleCron do
    @moduledoc """
    Schedule a recurring signal using cron expression.

    The signal will be delivered on the cron schedule until cancelled.

    ## Schema

    - `cron` - Cron expression (required, e.g., "*/5 * * * *" for every 5 mins)
    - `job_id` - Identifier for this job (for cancellation)
    - `signal_type` - Signal type to schedule (required)
    - `payload` - Signal payload data (default: %{})
    - `timezone` - Timezone for cron evaluation (optional)

    ## Example

        # Heartbeat every minute
        {Aikido.Actions.Scheduling.ScheduleCron, %{
          cron: "* * * * *",
          job_id: :heartbeat,
          signal_type: "agent.heartbeat"
        }}

        # Daily cleanup at 9am Eastern
        {Aikido.Actions.Scheduling.ScheduleCron, %{
          cron: "0 9 * * *",
          job_id: :daily_cleanup,
          signal_type: "maintenance.cleanup",
          timezone: "America/New_York"
        }}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{
                name: "schedule_cron",
                description: "Schedule a recurring signal using cron expression"
              }}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:cron, :string, description: "Cron expression", allow_nil?: false)
        argument(:job_id, :term, description: "Job identifier for cancellation", default: nil)
        argument(:signal_type, :string, description: "Signal type to schedule", allow_nil?: false)
        argument(:payload, :map, description: "Signal payload data", default: %{})
        argument(:timezone, :string, description: "Timezone for cron evaluation", default: nil)
        description("Schedule a recurring signal using cron expression")
        run(Aikido.Actions.Scheduling.ScheduleCron.Implementation)
      end
    end
  end

  defmodule CancelCron do
    @moduledoc """
    Cancel a scheduled cron job by its ID.

    ## Schema

    - `job_id` - Identifier of the job to cancel (required)

    ## Example

        {Aikido.Actions.Scheduling.CancelCron, %{job_id: :heartbeat}}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "cancel_cron", description: "Cancel a scheduled cron job"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:job_id, :term, description: "Job identifier to cancel", allow_nil?: false)
        description("Cancel a scheduled cron job")
        run(Aikido.Actions.Scheduling.CancelCron.Implementation)
      end
    end
  end
end
