defmodule Aikido.Thread.Consumer.Actions.Retry do
  @moduledoc "Retry through the native journal consumer's global credit state."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.Consumer.Demand

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state
    context = input.context.aikido
    {updated, directives} = Demand.retry(state, input.arguments, context)
    Aikido.Types.ActionResult.new(changes: Demand.changes(state, updated), directives: directives)
  end
end
