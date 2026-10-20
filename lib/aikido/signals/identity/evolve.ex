defmodule Aikido.Signals.Identity.Evolve do
  @moduledoc "Typed payload for `aikido.identity.evolve`."
  use Aikido.Signal

  signal do
    type "aikido.identity.evolve"

    schema do
      attribute :days, :integer do
        description "Days of simulated time to add"
        default 0
      end

      attribute :years, :integer do
        description "Years of simulated time to add"
        default 0
      end
    end
  end
end
