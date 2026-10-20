defmodule Aikido.Actions.Scheduling.CancelCron do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    job_id = input.arguments[:job_id]
    directive = Aikido.Directives.cron_cancel(job_id)
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
  end
end
