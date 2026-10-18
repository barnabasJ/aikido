defmodule Aikido.Slices.Identity.Actions.Evolve do
  @moduledoc """
  Evolves agent identity over simulated time.

  Advances the identity slice through simulated time, accumulating
  experiences and changes over days or years. Operates on the `:identity`
  slice — see `Aikido.Slices.Identity`.
  """

  use Aikido.Action

  action do
    name "identity_evolve"
    description "Evolve agent identity over simulated time"

    schema do
      attribute :days, :integer, description: "Days of simulated time to add", default: 0
      attribute :years, :integer, description: "Years of simulated time to add", default: 0
    end
  end

  def run(%Jido.Signal{data: params}, slice, _opts, _ctx) do
    identity = slice || Aikido.Slices.Identity.State.new()
    evolved = Aikido.Slices.Identity.State.evolve(identity, Map.to_list(params))
    {:ok, evolved, []}
  end
end
