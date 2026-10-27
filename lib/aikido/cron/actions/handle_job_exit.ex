defmodule Aikido.Cron.Actions.HandleJobExit do
  @moduledoc "Retires an exited scheduler and retries abnormal exits for an active definition."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    %{state: state, job_id: id, pid: pid, reason: reason} = input.arguments

    if state.jobs[id] == pid do
      next = %{state | jobs: Map.delete(state.jobs, id), monitors: Map.delete(state.monitors, id)}

      {next, directives} =
        if reason not in [:normal, :shutdown] && !match?({:shutdown, _}, reason) &&
             Map.has_key?(state.runtime_specs, id),
           do: Aikido.Cron.Registrations.retry(next, id, reason),
           else: {next, []}

      Aikido.Types.ActionResult.new(state: next, directives: directives)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
