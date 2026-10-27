defmodule Aikido.Cron.Registrations do
  @moduledoc "Pure transformations of cron job ownership, definitions and retry generations."

  @doc "Detach one job before returning effects that release its runtime resources."
  def detach(state, id) do
    pid = state.jobs[id]
    monitor = state.monitors[id]
    directives = release(id, pid, monitor)

    {%{state | jobs: Map.delete(state.jobs, id), monitors: Map.delete(state.monitors, id)},
     directives}
  end

  @doc "Describe release of an already detached process and its monitor."
  def release(id, pid, monitor) do
    monitors =
      if is_reference(monitor), do: [%Aikido.Directives.Demonitor{ref: monitor}], else: []

    monitors ++ [%Aikido.Cron.Directives.ShutdownJob{job_id: id, pid: pid, monitor_ref: monitor}]
  end

  @doc "Invalidate pending retries while preserving a monotonically increasing generation."
  def invalidate(state, id) do
    %{
      state
      | generations: Map.update(state.generations, id, 1, &(&1 + 1)),
        restart_attempts: Map.delete(state.restart_attempts, id)
    }
  end

  @doc "Queue a bounded backoff retry for the current generation of a missing job."
  def retry(state, id, reason) do
    attempt = Map.get(state.restart_attempts, id, 0)
    delay = min(500 * Integer.pow(2, min(attempt, 6)), 30_000)
    next = %{state | restart_attempts: Map.put(state.restart_attempts, id, attempt + 1)}

    signal = %Aikido.Signal{
      type: "aikido.agent.cron.retry",
      data: %{job_id: id, generation: state.generations[id]}
    }

    {next,
     [
       %Aikido.Cron.Directives.Report{
         event: :restart_scheduled,
         metadata: %{job_id: id, reason: reason, delay_ms: delay}
       },
       %Aikido.Directives.Schedule{delay_ms: delay, message: signal}
     ]}
  end

  @doc "Build a scheduler effect, including its expected retry generation when applicable."
  def start(id, spec, generation \\ nil) do
    %Aikido.Cron.Directives.Register{
      job_id: id,
      cron: spec.cron_expression,
      message: spec.message || %Aikido.Signal{type: spec.signal_type, data: spec.data},
      timezone: spec.timezone,
      runtime_spec: spec,
      generation: generation
    }
  end
end
