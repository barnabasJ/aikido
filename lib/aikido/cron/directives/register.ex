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
  alias Aikido.AgentServer.{State}

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
  @spec register_io(
          State.t(),
          term(),
          term(),
          term() | nil,
          term() | nil,
          Aikido.Signal.t() | nil
        ) ::
          {:ok, io_result()} | {:error, term()}
  def register_io(%State{} = state, cron_expr, message, logical_id, tz, origin \\ nil) do
    logical_id = if is_nil(logical_id), do: make_ref(), else: logical_id

    with {:ok, cron_spec} <-
           Aikido.Cron.Scheduler.validate_and_build_cron_spec(cron_expr, message, tz),
         # Keep inherited authority transient; cron_spec is persisted outside agent codecs.
         runtime_spec =
           Aikido.Cron.RuntimeSpec.dynamic(
             cron_spec.cron_expression,
             cron_spec.message,
             cron_spec.timezone,
             origin
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

  @impl true
  def exec(
        %{cron: cron_expr, message: message, job_id: logical_id, timezone: tz},
        input_signal,
        state
      ) do
    origin = Aikido.Signal.capture_tracing(input_signal)

    case Aikido.Cron.Directives.Register.register_io(
           state,
           cron_expr,
           message,
           logical_id,
           tz,
           origin
         ) do
      {:ok, io_result} ->
        publish_registration(io_result, input_signal, state)

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

  defp publish_registration(result, input_signal, state) do
    signal =
      result
      |> Map.take([:job_id, :pid, :monitor_ref, :cron_spec, :runtime_spec])
      |> Aikido.Cron.Signals.Registered.new!(source: "/agent/#{state.id}")
      |> Aikido.Signal.inherit(input_signal)

    AgentServer.cast(self(), signal)
  end
end
