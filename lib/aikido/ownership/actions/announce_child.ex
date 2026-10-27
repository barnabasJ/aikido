defmodule Aikido.Ownership.Actions.AnnounceChild do
  @moduledoc "Announces a ready child to its logical parent."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives:
        Aikido.Ownership.ParentBinding.announce(input.arguments.state, input.context.aikido)
    )
  end
end
