defmodule AgentExamples.CheckpointCounter.Actions.Crash do
  @moduledoc "Request an intentional hard crash without changing the counter."
  use Ash.Resource.Actions.Implementation

  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      directives: [%AgentExamples.CheckpointCounter.Directives.Crash{}]
    )
  end
end
