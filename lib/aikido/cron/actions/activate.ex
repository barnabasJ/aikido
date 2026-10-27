defmodule Aikido.Cron.Actions.Activate do
  @moduledoc "Rebuilds dynamic jobs and resource-declared schedules after activation."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    runtime = input.context.aikido

    declared =
      if runtime.skip_schedules, do: [], else: Aikido.Agent.Info.schedules(runtime.agent_module)

    {valid, invalid} = Aikido.Cron.Scheduler.classify_cron_specs(state.specs)
    dynamic = Map.drop(valid, Enum.map(declared, & &1.job_id))
    errors = Map.new(invalid, fn {id, _spec, reason} -> {id, reason} end)

    restored =
      Enum.map(Enum.sort(dynamic), fn {id, spec} ->
        Aikido.Cron.Registrations.start(
          id,
          Aikido.Cron.RuntimeSpec.dynamic(spec.cron_expression, spec.message, spec.timezone)
        )
      end)

    schedules =
      Enum.map(declared, fn spec ->
        runtime_spec =
          Aikido.Cron.RuntimeSpec.schedule(
            spec.cron_expression,
            spec.signal_type,
            spec.timezone,
            spec.data
          )

        Aikido.Cron.Registrations.start(spec.job_id, runtime_spec)
      end)

    Aikido.Types.ActionResult.new(
      state: %{state | specs: dynamic, errors: errors},
      directives: restored ++ schedules
    )
  end
end
