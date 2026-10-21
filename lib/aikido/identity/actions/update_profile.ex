defmodule Aikido.Identity.Actions.UpdateProfile do
  @moduledoc "Updates the identity profile using the input signal timestamp."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Identity.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    profile = input.arguments[:profile]
    identity = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Identity.Slice.update_profile(identity, profile, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
