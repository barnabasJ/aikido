defmodule Aikido.Thread.Consumer.Actions.ConfigureRetry do
  @moduledoc "ConfigureRetry through the native bounded consumer retry state."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.Consumer.Demand

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state
    {updated, directives} = Demand.configure_retry(state, input.arguments, input.context.aikido)
    Aikido.Types.ActionResult.new(changes: Demand.changes(state, updated), directives: directives)
  end
end
