defmodule Aikido.Cron.Directives.Cancel do
  @moduledoc """
  Cancel a recurring cron job in supervised work without blocking the agent.

  The descriptor queues an ordered cancellation request. The runtime retires
  ownership when that request is processed, before starting shutdown. Shutdown
  completion publishes `aikido.agent.cron.cancelled`; it cannot remove a newer
  job registered under the same ID.
  """
  use Aikido.Directive

  typed_struct do
    field :job_id, :term do
      allow_nil? false
      description "Logical cron job id within the agent"
    end
  end

  require Logger

  @impl true
  def exec(%{job_id: logical_id}, input_signal, state) do
    request =
      Aikido.Cron.Signals.CancelRequested.new!(%{job_id: logical_id},
        source: "/agent/#{state.id}"
      )

    Aikido.AgentServer.cast(self(), Aikido.Signal.inherit(request, input_signal))
    :ok
  end

  @doc false
  def shutdown_io(logical_id, input_signal, state) do
    pid = Map.get(state.cron_jobs, logical_id)

    task = build_shutdown_task(state, logical_id, pid)

    case Aikido.Directives.AsyncTask.start(task, input_signal, state) do
      {:ok, _task} ->
        :ok

      {:error, reason} ->
        force_shutdown_after_start_failure(state, logical_id, pid, reason)
    end

    :ok
  end

  defp build_shutdown_task(state, logical_id, pid) do
    %Aikido.Directives.AsyncTask{
      work: fn ->
        if is_pid(pid), do: Aikido.Cron.Scheduler.cancel(pid)
        Aikido.AgentServer.emit_cron_telemetry_event(state, :cancel, %{job_id: logical_id})

        Aikido.Cron.Signals.Cancelled.new!(
          %{job_id: logical_id, pid: pid, monitor_ref: state.cron_monitors[logical_id]},
          source: "/agent/#{state.id}"
        )
      end,
      error_type: "aikido.agent.cron.cancel.failed",
      payload: %{job_id: logical_id, pid: pid}
    }
  end

  defp force_shutdown_after_start_failure(state, logical_id, pid, reason) do
    # Ownership is already detached. Even a saturated task supervisor must
    # not leave the retired scheduler running indefinitely.
    if is_pid(pid), do: Process.exit(pid, :kill)
    Logger.warning("Forced cron shutdown after task startup failed: #{inspect(reason)}")

    Aikido.AgentServer.emit_cron_telemetry_event(state, :cancel_failed, %{
      job_id: logical_id,
      reason: reason
    })
  end
end
