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

  alias Aikido.Directives
  alias Jido.Signal

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
    use Aikido.Action

    action do
      name("schedule_signal")
      description("Schedule a signal to be delivered after a delay")

      schema do
        attribute(:delay_ms, :integer,
          description: "Delay in milliseconds",
          allow_nil?: false,
          constraints: [min: 0]
        )

        attribute(:signal_type, :string,
          description: "Signal type to schedule",
          allow_nil?: false
        )

        attribute(:payload, :map, description: "Signal payload data", default: %{})
        attribute(:source, :string, description: "Signal source path", default: "/scheduler")
      end
    end

    def run(
          %Jido.Signal{
            data: %{delay_ms: delay, signal_type: type, payload: payload, source: source}
          },
          _slice,
          _opts,
          _ctx
        ) do
      signal = Signal.new!(type, payload, source: source)
      directive = Directives.schedule(delay, signal)
      {:ok, %{scheduled_for_ms: delay, signal_type: type}, [directive]}
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
    use Aikido.Action

    action do
      name("schedule_timeout")
      description("Schedule a timeout signal for deadline handling")

      schema do
        attribute(:timeout_ms, :integer,
          description: "Timeout in milliseconds",
          allow_nil?: false,
          constraints: [min: 0]
        )

        attribute(:timeout_id, :term,
          description: "Identifier for this timeout",
          default: :default
        )

        attribute(:signal_type, :string,
          description: "Timeout signal type",
          default: "agent.timeout"
        )
      end
    end

    def run(
          %Jido.Signal{data: %{timeout_ms: timeout, timeout_id: id, signal_type: type}},
          _slice,
          _opts,
          _ctx
        ) do
      signal = Signal.new!(type, %{timeout_id: id}, source: "/timeout")
      directive = Directives.schedule(timeout, signal)
      {:ok, %{timeout_set: id, expires_in_ms: timeout}, [directive]}
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
    use Aikido.Action

    action do
      name("schedule_cron")
      description("Schedule a recurring signal using cron expression")

      schema do
        attribute(:cron, :string, description: "Cron expression", allow_nil?: false)
        attribute(:job_id, :term, description: "Job identifier for cancellation", default: nil)

        attribute(:signal_type, :string,
          description: "Signal type to schedule",
          allow_nil?: false
        )

        attribute(:payload, :map, description: "Signal payload data", default: %{})
        attribute(:timezone, :string, description: "Timezone for cron evaluation", default: nil)
      end
    end

    def run(
          %Jido.Signal{
            data: %{
              cron: cron_expr,
              job_id: job_id,
              signal_type: type,
              payload: payload,
              timezone: tz
            }
          },
          _slice,
          _opts,
          _ctx
        ) do
      signal = Signal.new!(type, payload, source: "/cron")

      opts =
        if job_id do
          [job_id: job_id]
        else
          []
        end

      opts =
        if tz do
          Keyword.put(opts, :timezone, tz)
        else
          opts
        end

      directive = Directives.cron(cron_expr, signal, opts)
      {:ok, %{cron_scheduled: cron_expr, job_id: job_id}, [directive]}
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
    use Aikido.Action

    action do
      name("cancel_cron")
      description("Cancel a scheduled cron job")

      schema do
        attribute(:job_id, :term, description: "Job identifier to cancel", allow_nil?: false)
      end
    end

    def run(%Jido.Signal{data: %{job_id: job_id}}, _slice, _opts, _ctx) do
      directive = Directives.cron_cancel(job_id)
      {:ok, %{cancelled_job: job_id}, [directive]}
    end
  end
end
