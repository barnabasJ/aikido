defmodule AgentExamples.Team.Actions.RecordMessage do
  @moduledoc "Records public message text and the coordinator-attested requester name."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    requester = get_in(input.context, [:aikido, :context, :aikido_requester])

    Aikido.Types.ActionResult.new(
      changes: %{
        last_message: input.arguments.text,
        last_requester: requester && requester.member
      }
    )
  end
end
