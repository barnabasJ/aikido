defmodule Aikido.Slices.Identity.Actions do
  @moduledoc "Native Ash state-transition actions for the identity slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :ensure, Aikido.ActionResult do
      argument :state, :term

      argument :profile, :map,
        description: "Initial profile map for new identities.",
        default: %{age: nil}

      description "Initialize identity state if missing."
      run {Aikido.Slices.Identity.Actions.Implementation, action: :ensure}
    end

    action :evolve, Aikido.ActionResult do
      argument :state, :term
      argument :days, :integer, description: "Days of simulated time to add", default: 0
      argument :years, :integer, description: "Years of simulated time to add", default: 0
      description "Evolve agent identity over simulated time"
      run {Aikido.Slices.Identity.Actions.Implementation, action: :evolve}
    end

    action :update_profile, Aikido.ActionResult do
      argument :state, :term

      argument :profile, :map,
        description: "Partial profile map to merge into the identity.",
        allow_nil?: false

      description "Merge a partial profile map into the identity profile."
      run {Aikido.Slices.Identity.Actions.Implementation, action: :update_profile}
    end
  end
end
