defmodule Aikido.Cron.Directives.ShutdownJob do
  @moduledoc "Stops a detached scheduler in supervised work and reports cancellation."
  use Aikido.Directive

  typed_struct do
    field :job_id, :term do
      description "Logical identity of the detached scheduler."
      allow_nil? false
    end

    field :pid, :term do
      description "Detached scheduler process, or nil when already absent."
    end

    field :monitor_ref, :term do
      description "Released monitor reported in the cancellation acknowledgement."
    end
  end

  @impl true
  def exec(job, signal, runtime) do
    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        if is_pid(job.pid), do: Aikido.Cron.Scheduler.cancel(job.pid)
        Aikido.Cron.Telemetry.emit(runtime, :cancel, %{job_id: job.job_id})

        Aikido.Cron.Signals.Cancelled.new!(Map.take(job, [:job_id, :pid, :monitor_ref]),
          source: "/agent/#{runtime.id}"
        )
      end,
      error_type: "aikido.agent.cron.cancel.failed",
      payload: %{job_id: job.job_id}
    }

    case Aikido.Directives.AsyncTask.start(task, signal, runtime) do
      {:ok, _} ->
        :ok

      {:error, _reason} ->
        if is_pid(job.pid), do: Process.exit(job.pid, :kill)
        :ok
    end
  end
end
