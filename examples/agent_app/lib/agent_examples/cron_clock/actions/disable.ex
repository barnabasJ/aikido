defmodule AgentExamples.CronClock.Actions.Disable do
  @moduledoc "Reject any queued ticks and request cancellation of the recurring job."
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | enabled: false},
      directives: [
        %Aikido.Cron.Directives.Cancel{job_id: :clock}
      ]
    )
  end
end
