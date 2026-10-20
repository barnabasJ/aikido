defmodule Aikido.Slices.Identity.Implementation do
  @moduledoc """
  Pure reducers for identity initialization, evolution and profile changes.

  The native action name selects `:ensure`, `:evolve` or `:update_profile`.
  Uses native payload arguments and the input signal's timestamp to return the
  next identity state without directives.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(%{action: %{name: :ensure}} = input, _opts, _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Identity{} = identity ->
        Aikido.Types.ActionResult.new(state: identity, directives: [])

      _ ->
        Aikido.Types.ActionResult.new(
          state:
            Aikido.Slices.Identity.new(Keyword.merge(Map.to_list(data), now: timestamp(input))),
          directives: []
        )
    end
  end

  @impl true
  def run(%{action: %{name: :evolve}} = input, _opts, _context) do
    params = Map.delete(input.arguments, :state)
    slice = input.arguments.state
    identity = slice || Aikido.Slices.Identity.new(now: timestamp(input))

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
    slice = input.arguments.state
    identity = update_profile_ensure_identity(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Identity.update_profile(identity, profile, now: timestamp(input)),
      directives: []
    )
  end

  defp update_profile_ensure_identity(%Aikido.Slices.Identity{} = identity, _input) do
    identity
  end

  defp update_profile_ensure_identity(_, input) do
    Aikido.Slices.Identity.new(now: timestamp(input))
  end

  defp timestamp(input),
    do: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))
end
