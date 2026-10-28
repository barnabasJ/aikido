defmodule Aikido.Cron.Actions.StopJobs do
  @moduledoc "Releases active schedulers at graceful shutdown while retaining durable definitions."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {state, directives} =
      Enum.reduce(
        Enum.sort(Map.keys(input.arguments.state.jobs)),
        {input.arguments.state, []},
        fn id, {state, directives} ->
          {next, release} = Aikido.Cron.Registrations.detach(state, id)
          {Aikido.Cron.Registrations.invalidate(next, id), directives ++ release}
        end
      )

    Aikido.Types.ActionResult.new(
      changes: %{
        jobs: state.jobs,
        monitors: state.monitors,
        generations: state.generations,
        restart_attempts: state.restart_attempts
      },
      directives: directives
    )
  end
end
