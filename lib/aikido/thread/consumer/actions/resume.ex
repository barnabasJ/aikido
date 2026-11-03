defmodule Aikido.Thread.Consumer.Actions.Resume do
  @moduledoc "Continue source demand after an explicit drain pause."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.Consumer.Demand

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state

    with {:ok, updated, directives} <- Demand.resume(state, input.context.aikido) do
      Aikido.Types.ActionResult.new(
        changes: Demand.changes(state, updated),
        directives: directives
      )
    end
  end
end
