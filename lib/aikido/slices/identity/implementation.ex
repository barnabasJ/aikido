defmodule Aikido.Slices.Identity.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :ensure], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Identity{} = identity ->
        Aikido.ActionResult.new(state: identity, directives: [])

      _ ->
        Aikido.ActionResult.new(
          state: Aikido.Slices.Identity.new(Map.to_list(data)),
          directives: []
        )
    end
  end

  @impl true
  def run(input, [action: :evolve], _context) do
    params = Map.delete(input.arguments, :state)
    slice = input.arguments.state
    identity = slice || Aikido.Slices.Identity.new()
    evolved = Aikido.Slices.Identity.evolve(identity, Map.to_list(params))
    Aikido.ActionResult.new(state: evolved, directives: [])
  end

  @impl true
  def run(input, [action: :update_profile], _context) do
    profile = input.arguments[:profile]
    slice = input.arguments.state
    identity = update_profile_ensure_identity(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Identity.update_profile(identity, profile),
      directives: []
    )
  end

  defp update_profile_ensure_identity(%Aikido.Slices.Identity{} = identity) do
    identity
  end

  defp update_profile_ensure_identity(_) do
    Aikido.Slices.Identity.new()
  end
end
