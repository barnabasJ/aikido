defmodule Aikido.Signals.Identity.UpdateProfile do
  @moduledoc "Typed payload for `aikido.identity.update_profile`."
  use Aikido.Signal

  signal do
    type "aikido.identity.update_profile"

    schema do
      attribute :profile, :map do
        description "Partial profile map to merge into the identity."
        allow_nil? false
      end
    end
  end
end
