defmodule Aikido.Slices.Identity.Actions.Evolve do
  @moduledoc "Advances identity age and revision using the input signal timestamp."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Identity.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    params = Map.delete(input.arguments, :state)
    identity = input.arguments.state

    evolved =
      Aikido.Slices.Identity.evolve(
        identity,
        Keyword.merge(Map.to_list(params), ActionOptions.from_input(input))
      )

    Aikido.Types.ActionResult.new(state: evolved, directives: [])
  end
end
