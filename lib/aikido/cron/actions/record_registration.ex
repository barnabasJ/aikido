defmodule Aikido.Cron.Actions.RecordRegistration do
  @moduledoc "Adopts a scheduler result, releasing replaced or stale processes through directives."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    %{
      state: state,
      job_id: id,
      pid: pid,
      monitor_ref: monitor,
      cron_spec: spec,
      runtime_spec: runtime_spec,
      generation: generation
    } = input.arguments

    cond do
      state.jobs[id] == pid && state.monitors[id] == monitor ->
        Aikido.Types.ActionResult.new(state: state)

      !is_nil(generation) && (state.generations[id] != generation || Map.has_key?(state.jobs, id)) ->
        Aikido.Types.ActionResult.new(
          state: state,
          directives: Aikido.Cron.Registrations.release(id, pid, monitor)
        )

      true ->
        {next, directives} =
          if Map.has_key?(state.jobs, id),
            do: Aikido.Cron.Registrations.detach(state, id),
            else: {state, []}

        next =
          if is_nil(generation), do: Aikido.Cron.Registrations.invalidate(next, id), else: next

        specs =
          if runtime_spec.kind == :dynamic,
            do: Map.put(next.specs, id, spec),
            else: Map.delete(next.specs, id)

        next = %{
          next
          | jobs: Map.put(next.jobs, id, pid),
            monitors: Map.put(next.monitors, id, monitor),
            specs: specs,
            runtime_specs: Map.put(next.runtime_specs, id, runtime_spec),
            restart_attempts: Map.delete(next.restart_attempts, id),
            errors: Map.delete(next.errors, id)
        }

        restarted =
          if is_nil(generation),
            do: [],
            else: [
              %Aikido.Cron.Directives.Report{
                event: :restart_succeeded,
                metadata: %{job_id: id, cron_expression: runtime_spec.cron_expression}
              },
              %Aikido.Directives.Emit{
                signal: %Aikido.Signal{
                  type: "aikido.agent.cron.restarted",
                  data: %{job_id: id, pid: pid}
                }
              }
            ]

        Aikido.Types.ActionResult.new(state: next, directives: directives ++ restarted)
    end
  end
end
