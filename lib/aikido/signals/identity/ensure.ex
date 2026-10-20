defmodule Aikido.Signals.Identity.Ensure do
  @moduledoc "Typed payload for `aikido.identity.ensure`."
  use Aikido.Signal

  signal do
    type "aikido.identity.ensure"

    schema do
      attribute :profile, :map do
        description "Initial profile map for new identities."
        default %{age: nil}
      end
    end
  end
end
