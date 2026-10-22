defmodule AgentExamples.VerifiedAssistant.Actions.VerifyEvidence do
  @moduledoc "Accepts an answer only when every supplied blocking todo has completed evidence."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    {:ok,
     input.arguments.todos != [] &&
       Enum.all?(
         input.arguments.todos,
         &(&1.status == :completed && &1.result == "Checked by the evidence tool")
       )}
  end
end
