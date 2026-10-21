defmodule Aikido.Cron.Actions.Cancel do
  @moduledoc """
  Pure reducer that requests cancellation of the cron job identified by `job_id`.

  Returns the supplied `state` and a `CronCancel` directive; it does not stop
  scheduler processes itself.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    job_id = input.arguments[:job_id]
    directive = Aikido.Directives.cron_cancel(job_id)
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
  end
end
