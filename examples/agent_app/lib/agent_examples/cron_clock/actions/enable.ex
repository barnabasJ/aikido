defmodule AgentExamples.CronClock.Actions.Enable do
  @moduledoc "Enable tick acceptance and request one recurring job under a stable job ID."
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | enabled: true},
      directives: [
        %Aikido.Cron.Directives.Register{
          job_id: :clock,
          cron: "*/2 * * * * * *",
          message: %Aikido.Signal{type: "examples.cron_clock.tick", data: %{}}
        }
      ]
    )
  end
end
