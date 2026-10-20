defmodule Aikido.Directives.CronCancel do
  @moduledoc """
  Cancel a previously registered cron job for this agent by job_id.

  ## Fields

  - `job_id` - The logical job id to cancel

  ## Examples

      %CronCancel{job_id: :heartbeat}
  """

  use Aikido.Directive

  typed_struct do
    field :job_id, :term, allow_nil?: false, description: "Logical cron job id within the agent"
  end

  require Logger
  alias Aikido.AgentServer

  alias Aikido.AgentServer.Signal.CronCancelled
  alias Aikido.AgentServer.State

  @impl true
  def exec(%{job_id: logical_id}, input_signal, %State{} = state) do
    pid = Map.get(state.cron_jobs, logical_id)
    monitor_ref = Map.get(state.cron_monitors, logical_id)

    cancel_io(pid, monitor_ref)

    emit_cancellation(state, logical_id, pid, monitor_ref, input_signal)

    :ok
  end

  defp cancel_io(pid, monitor_ref) do
    if is_pid(pid) and Process.alive?(pid) do
      Aikido.Scheduler.cancel(pid)
    end

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    :ok
  end

  defp emit_cancellation(%State{} = state, logical_id, pid, monitor_ref, input_signal) do
    signal =
      CronCancelled.new!(
        %{
          job_id: logical_id,
          pid: pid,
          monitor_ref: monitor_ref
        },
        source: "/agent/#{state.id}"
      )

    _ = AgentServer.cast(self(), Aikido.SignalCtx.inherit(signal, input_signal))

    Logger.debug("AgentServer #{state.id} cancelled cron job #{inspect(logical_id)}")

    AgentServer.emit_cron_telemetry_event(state, :cancel, %{job_id: logical_id})
  end
end
