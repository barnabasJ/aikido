defmodule AgentExamples.Journal.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.ActionResult.new(state: %{entries: state.entries ++ [input.arguments.text]})
  end
end
