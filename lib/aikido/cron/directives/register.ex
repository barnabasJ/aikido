defmodule Aikido.Cron.Directives.Register do
  @moduledoc """
  Register or update a recurring cron job for this agent.

  The job is owned by the agent's `id` and identified within that agent
  by `job_id`. On each tick, the scheduler sends `message` (or `signal`)
  back to the agent via `Aikido.AgentServer.cast/2`. Incomplete signal
  descriptors receive a fresh ID and timestamp on each occurrence. A fully
  constructed signal retains its caller-supplied identity.

  ## Fields

  - `job_id` - Logical id within the agent (for upsert/cancel). Auto-generated if nil.
  - `cron` - Cron expression string (e.g., "* * * * *", "@daily", "*/5 * * * *")
  - `message` - Signal or message to send on each tick
  - `timezone` - Optional timezone identifier (default: UTC)

  ## Examples

      # Every minute, send a tick signal
      %Aikido.Cron.Directives.Register{cron: "* * * * *", message: tick_signal, job_id: :heartbeat}

      # Daily at midnight, send a cleanup signal
      %Aikido.Cron.Directives.Register{cron: "@daily", message: cleanup_signal, job_id: :daily_cleanup}

      # Every 5 minutes with timezone
      %Aikido.Cron.Directives.Register{cron: "*/5 * * * *", message: check_signal, job_id: :check, timezone: "America/New_York"}
  """

  require Logger
  alias Aikido.AgentServer

  use Aikido.Directive

  typed_struct do
    field :runtime_spec, :term do
      description "Prepared declaration or retry spec; dynamic registrations build one at the I/O boundary."
    end

    field :generation, :term do
      description "Expected registration generation for a retry; nil starts a new registration."
    end

    field :job_id, :term do
      allow_nil? true
      description "Logical cron job id within the agent"
    end

    field :cron, :term do
      allow_nil? false
      description "Cron expression (e.g. \"* * * * *\", \"@daily\")"
    end

    field :message, :term do
      allow_nil? false
      description "Signal or message to send on each tick"
    end

    field :timezone, :term do
      allow_nil? true
      description "Timezone identifier (optional)"
    end
  end

  @typedoc false
  @type io_result :: %{
          job_id: term(),
          pid: pid(),
          monitor_ref: reference(),
          cron_spec: map(),
          runtime_spec: term()
        }

  defp build_io_result(logical_id, pid, cron_spec, runtime_spec) do
    %{
      job_id: logical_id,
      pid: pid,
      monitor_ref: Process.monitor(pid),
      cron_spec: cron_spec,
      runtime_spec: runtime_spec
    }
  end

  @impl true
  def exec(descriptor, input_signal, state) do
    logical_id = if is_nil(descriptor.job_id), do: make_ref(), else: descriptor.job_id
    origin = Aikido.Signal.capture_tracing(input_signal)

    result =
      with {:ok, cron_spec} <-
             Aikido.Cron.Scheduler.validate_and_build_cron_spec(
               descriptor.cron,
               descriptor.message,
               descriptor.timezone
             ),
           runtime_spec =
             descriptor.runtime_spec ||
               Aikido.Cron.RuntimeSpec.dynamic(
                 cron_spec.cron_expression,
                 cron_spec.message,
                 cron_spec.timezone,
                 origin
               ),
           {:ok, pid} <- Aikido.Cron.Scheduler.start_job(state.id, logical_id, runtime_spec) do
        {:ok, build_io_result(logical_id, pid, cron_spec, runtime_spec)}
      end

    signal =
      case result do
        {:ok, result} ->
          Aikido.Cron.Telemetry.emit(state, :register, %{
            job_id: logical_id,
            cron_expression: descriptor.cron
          })

          Aikido.Cron.Signals.Registered.new!(Map.put(result, :generation, descriptor.generation),
            source: "/agent/#{state.id}"
          )

        {:error, reason} ->
          Logger.error(
            "Cron job #{inspect(logical_id)} could not start: #{Aikido.Telemetry.Formatter.safe_inspect(reason)}"
          )

          Aikido.Cron.Telemetry.emit(state, :register_failed, %{
            job_id: logical_id,
            reason: reason
          })

          Aikido.Cron.Signals.RegistrationFailed.new!(
            %{job_id: logical_id, reason: reason, generation: descriptor.generation},
            source: "/agent/#{state.id}"
          )
      end

    AgentServer.cast(self(), Aikido.Signal.inherit(signal, input_signal))
    :ok
  end
end
