defmodule Aikido.Cron.Actions.CancelJob do
  @moduledoc "Removes a schedule definition and invalidates retries before stopping its process."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    id = input.arguments.job_id
    {state, directives} = Aikido.Cron.Registrations.detach(input.arguments.state, id)
    state = Aikido.Cron.Registrations.invalidate(state, id)

    changes = %{
      jobs: state.jobs,
      monitors: state.monitors,
      generations: state.generations,
      restart_attempts: state.restart_attempts,
      specs: Map.delete(state.specs, id),
      runtime_specs: Map.delete(state.runtime_specs, id),
      errors: Map.delete(state.errors, id)
    }

    Aikido.Types.ActionResult.new(changes: changes, directives: directives)
  end
end
