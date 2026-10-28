defmodule AgentExamples.VerifiedAssistant.Tools.VerifyEvidence do
  @moduledoc "Accepts an answer only when every supplied blocking todo has completed evidence."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    accepted? =
      input.arguments.todos != [] &&
        Enum.all?(
          input.arguments.todos,
          &(&1.status == :completed && &1.result == "Checked by the evidence tool")
        )

    Aikido.AiReact.TodoVerification.new(%{
      accepted?: accepted?,
      feedback:
        if(accepted?,
          do: nil,
          else:
            "Call record_evidence with the delivered work item's ID before claiming completion."
        ),
      data: (input.arguments.data || 0) + 1
    })
  end
end
