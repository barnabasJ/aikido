defmodule Aikido.Directives.Cron do
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
      %Cron{cron: "* * * * *", message: tick_signal, job_id: :heartbeat}

      # Daily at midnight, send a cleanup signal
      %Cron{cron: "@daily", message: cleanup_signal, job_id: :daily_cleanup}

      # Every 5 minutes with timezone
      %Cron{cron: "*/5 * * * *", message: check_signal, job_id: :check, timezone: "America/New_York"}
  """

  require Logger

  alias Aikido.AgentServer
  alias Aikido.AgentServer.{CronRuntimeSpec, State}

  use Aikido.Directive

  typed_struct do
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

  # Pure I/O for cron registration. Validates the expression, spawns
  # the scheduler job and monitors it.
  # Returns the data the cascade callback
  # (`maybe_track_cron_registered/2`) needs to install in the runtime
  # maps. It does not mutate `%AgentServer.State{}`; runtime field writes
  # flow through the cascade callbacks.
  @doc false
  @spec register_io(State.t(), term(), term(), term() | nil, term() | nil) ::
          {:ok, io_result()} | {:error, term()}
  def register_io(%State{} = state, cron_expr, message, logical_id, tz) do
    logical_id = if is_nil(logical_id), do: make_ref(), else: logical_id

    with {:ok, cron_spec} <- Aikido.Scheduler.validate_and_build_cron_spec(cron_expr, message, tz),
         runtime_spec =
           CronRuntimeSpec.dynamic(
             cron_spec.cron_expression,
             cron_spec.message,
             cron_spec.timezone
           ),
         {:ok, pid} <- AgentServer.start_runtime_cron_job(state, logical_id, runtime_spec) do
      {:ok, build_io_result(logical_id, pid, cron_spec, runtime_spec)}
    end
  end

  defp build_io_result(logical_id, pid, cron_spec, runtime_spec) do
    %{
      job_id: logical_id,
      pid: pid,
      monitor_ref: Process.monitor(pid),
      cron_spec: cron_spec,
      runtime_spec: runtime_spec
    }
  end

  alias Aikido.AgentServer.Signals.CronRegistered

  @impl true
  def exec(
        %{cron: cron_expr, message: message, job_id: logical_id, timezone: tz},
        input_signal,
        state
      ) do
    case Aikido.Directives.Cron.register_io(state, cron_expr, message, logical_id, tz) do
      {:ok, io_result} ->
        signal =
          CronRegistered.new!(
            %{
              job_id: io_result.job_id,
              pid: io_result.pid,
              monitor_ref: io_result.monitor_ref,
              cron_spec: io_result.cron_spec,
              runtime_spec: io_result.runtime_spec
            },
            source: "/agent/#{state.id}"
          )

        _ = AgentServer.cast(self(), Aikido.Signal.inherit(signal, input_signal))

        Logger.debug(
          "AgentServer #{state.id} registered cron job #{inspect(io_result.job_id)}: #{cron_expr}"
        )

        AgentServer.emit_cron_telemetry_event(state, :register, %{
          job_id: io_result.job_id,
          cron_expression: cron_expr
        })

        :ok

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to register cron job #{inspect(logical_id)}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
