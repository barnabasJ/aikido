defmodule Aikido.Slices.Identity.Implementation do
  @moduledoc """
  Pure reducers for preserving identity, evolution and profile changes.

  The native action name selects `:ensure`, `:evolve` or `:update_profile`.
  Uses native payload arguments and the input signal's timestamp to return the
  next identity state without directives.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(%{action: %{name: :ensure}} = input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end

  @impl true
  def run(%{action: %{name: :evolve}} = input, _opts, _context) do
    params = Map.delete(input.arguments, :state)
    identity = input.arguments.state

    evolved =
      Aikido.Slices.Identity.evolve(
        identity,
        Keyword.merge(Map.to_list(params), now: timestamp(input))
      )

    Aikido.Types.ActionResult.new(state: evolved, directives: [])
  end

  @impl true
  def run(%{action: %{name: :update_profile}} = input, _opts, _context) do
    profile = input.arguments[:profile]
    identity = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Identity.update_profile(identity, profile, now: timestamp(input)),
      directives: []
    )
  end

  defp timestamp(input),
    do: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))
end
