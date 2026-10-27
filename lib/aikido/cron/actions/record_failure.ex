defmodule Aikido.Cron.Actions.RecordFailure do
  @moduledoc "Records concrete startup failures and backs off still-current restart attempts."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    %{state: state, job_id: id, reason: reason, generation: generation} = input.arguments

    if is_nil(generation) || state.generations[id] == generation do
      next = %{state | errors: Map.put(state.errors, id, reason)}

      {next, directives} =
        if generation && Map.has_key?(state.runtime_specs, id),
          do: Aikido.Cron.Registrations.retry(next, id, reason),
          else: {next, []}

      Aikido.Types.ActionResult.new(state: next, directives: directives)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
