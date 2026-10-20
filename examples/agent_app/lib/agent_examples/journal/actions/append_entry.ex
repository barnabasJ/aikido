defmodule AgentExamples.Journal.Actions.AppendEntry do
  @moduledoc "Appends the supplied text to the journal entries."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{entries: state.entries ++ [input.arguments.text]})
  end
end
