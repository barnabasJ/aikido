defmodule Aikido.Slices.Identity do
  @moduledoc """
  Identity slice — owns the `:identity` key in agent state, mounted as a
  `%Aikido.Slices.Identity.State{}` self-model.

  ## State shape

  Bound to `Aikido.Slices.Identity.State.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `aikido.identity.*` signal materializes a fresh
  `%Aikido.Slices.Identity.State{}` via the relevant action.

  ## Routes

      route "aikido.identity.ensure",         Actions.Ensure
      route "aikido.identity.evolve",         Actions.Evolve
      route "aikido.identity.update_profile", Actions.UpdateProfile

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Aikido.Agent, default_slices: %{identity: false}

      agent do
        name "minimal"
      end
  """

  alias Aikido.Slices.Identity.Actions
  alias Aikido.Slices.Identity.State

  use Aikido.Slice

  slice do
    name "identity"
    description "Identity self-model for agent (lifecycle facts, profile)."

    schema do
      attribute :rev, :integer, allow_nil?: false, default: 0, description: "Monotonic revision"

      attribute :profile, :map,
        allow_nil?: false,
        default: %{age: nil},
        description: "Lifecycle facts"

      attribute :created_at, :integer, allow_nil?: false, description: "Creation timestamp (ms)"

      attribute :updated_at, :integer,
        allow_nil?: false,
        description: "Last update timestamp (ms)"
    end

    state_transform {Aikido.Schema, :to_struct, [State]}
  end

  signal_routes do
    route "aikido.identity.ensure", Actions.Ensure
    route "aikido.identity.evolve", Actions.Evolve
    route "aikido.identity.update_profile", Actions.UpdateProfile
  end

  capabilities do
    capability :identity
  end

  @identity_section %Spark.Dsl.Section{
    name: :identity,
    describe: "Configuration block contributed by Aikido.Slices.Identity.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@identity_section],
    transformers: [Aikido.Slices.Identity.Transformers.RegisterContribution]
end
