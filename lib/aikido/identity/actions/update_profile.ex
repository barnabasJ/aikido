defmodule Aikido.Identity.Actions.UpdateProfile do
  @moduledoc "Updates the identity profile using the input signal timestamp."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    profile = input.arguments[:profile]
    identity = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: %{
        identity
        | profile: Map.merge(identity.profile, profile),
          rev: identity.rev + 1,
          updated_at: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))
      }
    )
  end
end
