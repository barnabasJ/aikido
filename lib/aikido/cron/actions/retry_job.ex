defmodule Aikido.Cron.Actions.RetryJob do
  @moduledoc "Restarts only the still-current generation of an absent scheduler."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    %{state: state, job_id: id, generation: generation} = input.arguments
    spec = state.runtime_specs[id]

    directives =
      if spec && state.generations[id] == generation && !Map.has_key?(state.jobs, id),
        do: [Aikido.Cron.Registrations.start(id, spec, generation)],
        else: []

    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end
end
