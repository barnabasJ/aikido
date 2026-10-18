defmodule Aikido.Slices.Identity do
  @moduledoc "Identity slice — owns the `:identity` key in agent state, mounted as a\n`%Aikido.Slices.Identity.State{}` self-model.\n\n## State shape\n\nBound to `Aikido.Slices.Identity.State.schema/0`. The slice starts as `nil` (lazy-init);\nthe first inbound `aikido.identity.*` signal materializes a fresh\n`%Aikido.Slices.Identity.State{}` via the relevant action.\n\n## Routes\n\n    route \"aikido.identity.ensure\",         Actions.Ensure\n    route \"aikido.identity.evolve\",         Actions.Evolve\n    route \"aikido.identity.update_profile\", Actions.UpdateProfile\n\n## Default slice\n\nThis slice is automatically included as a default slice for all agents\nunless explicitly disabled:\n\n    use Aikido.Agent, default_slices: %{identity: false}\n\n    agent do\n      name \"minimal\"\n    end\n"
  alias Aikido.Slices.Identity.State
  use Aikido.Slice

  @persist {:aikido_slice_schema, State}

  slice do
    name "identity"
    description "Identity self-model for agent (lifecycle facts, profile)."

  end

  signal_routes do
    route "aikido.identity.ensure", {Aikido.Slices.Identity.Actions, :ensure}
    route "aikido.identity.evolve", {Aikido.Slices.Identity.Actions, :evolve}
    route "aikido.identity.update_profile", {Aikido.Slices.Identity.Actions, :update_profile}
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
