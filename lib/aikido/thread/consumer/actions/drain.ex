defmodule Aikido.Thread.Consumer.Actions.Drain do
  @moduledoc "Request a fresh authorized head check for each source before pausing."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.Consumer.Demand

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state

    with {:ok, updated, directives} <- Demand.drain(state, input.context.aikido) do
      Aikido.Types.ActionResult.new(
        changes: Demand.changes(state, updated),
        directives: directives
      )
    end
  end
end
