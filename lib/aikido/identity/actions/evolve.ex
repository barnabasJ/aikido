defmodule Aikido.Identity.Actions.Evolve do
  @moduledoc "Advances identity age and revision using the input signal timestamp."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    identity = input.arguments.state
    increment = (input.arguments.years || 0) + div(input.arguments.days || 0, 365)
    age = (identity.profile[:age] || 0) + increment

    Aikido.Types.ActionResult.new(
      state: %{
        identity
        | profile: Map.put(identity.profile, :age, age),
          rev: identity.rev + 1,
          updated_at: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))
      }
    )
  end
end
