defmodule Aikido.Signals.Identity.Evolve do
  @moduledoc "Typed payload for `aikido.identity.evolve`."
  use Aikido.Signal

  signal do
    type "aikido.identity.evolve"

    schema do
      attribute :days, :integer, description: "Days of simulated time to add", default: 0

      attribute :years, :integer, description: "Years of simulated time to add", default: 0
    end
  end
end
