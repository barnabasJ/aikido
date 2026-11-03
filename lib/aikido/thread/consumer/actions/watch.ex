defmodule Aikido.Thread.Consumer.Actions.Watch do
  @moduledoc "Watch through the native journal consumer's global credit state."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.Consumer.Demand

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state
    context = input.context.aikido

    busy? =
      Enum.any?(state.credits, fn credit ->
        credit.source == input.arguments.source && credit.path == input.arguments.path &&
          credit.channel == input.arguments.channel
      end)

    if busy? && (input.arguments.reset? || input.arguments[:after]) do
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :after,
         message:
           "Cannot reset a journal cursor while its request or SQL batch is outstanding. Complete or fail that work before resetting."
       )}
    else
      {updated, directives} = Demand.watch(state, input.arguments, context)

      Aikido.Types.ActionResult.new(
        changes: Demand.changes(state, updated),
        directives: directives
      )
    end
  end
end
