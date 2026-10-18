defmodule Aikido.Actions.Scheduling do
  @moduledoc "Base actions for scheduling delayed signals and timeouts.\n\nThese actions wrap the `Schedule` directive for common timing patterns.\n\n## Usage\n\n    use Aikido.Agent\n\n    agent do\n      name \"timed_worker\"\n    end\n\n    signal_routes do\n      route \"work.start\", MyStartAction       # Might schedule a timeout\n      route \"work.timeout\", MyTimeoutHandler\n    end\n"
  alias Aikido.Directives
  alias Jido.Signal

  defmodule ScheduleSignal do
    @moduledoc "Schedule a signal to be delivered after a delay.\n\nThe signal will be delivered to the agent's own mailbox after\nthe specified delay.\n\n## Schema\n\n- `delay_ms` - Delay in milliseconds (required)\n- `signal_type` - Signal type to schedule (required)\n- `payload` - Signal payload data (default: %{})\n- `source` - Signal source path (default: \"/scheduler\")\n\n## Example\n\n    # Schedule a completion check\n    {Aikido.Actions.Scheduling.ScheduleSignal, %{\n      delay_ms: 5000,\n      signal_type: \"work.check\",\n      payload: %{attempt: 1}\n    }}\n"
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

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(
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
    @moduledoc "Schedule a timeout signal for deadline handling.\n\nConvenience wrapper that schedules a standard timeout signal\nthat can be handled to fail the agent or take corrective action.\n\n## Schema\n\n- `timeout_ms` - Timeout duration in milliseconds (required)\n- `timeout_id` - Identifier for this timeout (default: :default)\n- `signal_type` - Signal type for timeout (default: \"agent.timeout\")\n\n## Example\n\n    # Set a 30 second deadline\n    {Aikido.Actions.Scheduling.ScheduleTimeout, %{\n      timeout_ms: 30_000,\n      timeout_id: :work_deadline\n    }}\n"
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

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(
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
    @moduledoc "Schedule a recurring signal using cron expression.\n\nThe signal will be delivered on the cron schedule until cancelled.\n\n## Schema\n\n- `cron` - Cron expression (required, e.g., \"*/5 * * * *\" for every 5 mins)\n- `job_id` - Identifier for this job (for cancellation)\n- `signal_type` - Signal type to schedule (required)\n- `payload` - Signal payload data (default: %{})\n- `timezone` - Timezone for cron evaluation (optional)\n\n## Example\n\n    # Heartbeat every minute\n    {Aikido.Actions.Scheduling.ScheduleCron, %{\n      cron: \"* * * * *\",\n      job_id: :heartbeat,\n      signal_type: \"agent.heartbeat\"\n    }}\n\n    # Daily cleanup at 9am Eastern\n    {Aikido.Actions.Scheduling.ScheduleCron, %{\n      cron: \"0 9 * * *\",\n      job_id: :daily_cleanup,\n      signal_type: \"maintenance.cleanup\",\n      timezone: \"America/New_York\"\n    }}\n"
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

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(
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
    @moduledoc "Cancel a scheduled cron job by its ID.\n\n## Schema\n\n- `job_id` - Identifier of the job to cancel (required)\n\n## Example\n\n    {Aikido.Actions.Scheduling.CancelCron, %{job_id: :heartbeat}}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "cancel_cron", description: "Cancel a scheduled cron job"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:job_id, :term, description: "Job identifier to cancel", allow_nil?: false)
        description("Cancel a scheduled cron job")

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: %{job_id: job_id}}, _slice, _opts, _ctx) do
      directive = Directives.cron_cancel(job_id)
      {:ok, %{cancelled_job: job_id}, [directive]}
    end
  end
end
