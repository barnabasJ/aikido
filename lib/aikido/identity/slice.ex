defmodule Aikido.Identity.Slice do
  @moduledoc """
  Identity slice — owns the `:identity` key in agent state, mounted as a
  `%Aikido.Identity.Slice{}` self-model.

  ## State shape

  Declared by the embedded resource attributes. Mounted slices are initialized
  through their native create action before receiving signals. Reducers require
  the initialized resource struct and retain native Ash type validation.

  ## Routes

      route Aikido.Identity.Signals.Evolve, Aikido.Identity.Actions.Evolve
      route Aikido.Identity.Signals.UpdateProfile, Aikido.Identity.Actions.UpdateProfile

  Mount with `slice :identity, Aikido.Identity.Slice` inside an agent resource.

  """

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension]

  slice do
    name "identity"
    description "Identity self-model for agent (lifecycle facts, profile)."

    schema do
      attribute :rev, :integer do
        description "Monotonic revision"
        public? true
        allow_nil? false
        default 0
      end

      attribute :profile, :map do
        description "Lifecycle facts"
        public? true
        allow_nil? false
        default %{age: nil}
      end

      attribute :created_at, :integer do
        description "Creation timestamp (ms)"
        default 0
        public? true
        allow_nil? false
      end

      attribute :updated_at, :integer do
        description "Last update timestamp (ms)"
        default 0
        public? true
        allow_nil? false
      end
    end

    route Aikido.Identity.Signals.Evolve, Aikido.Identity.Actions.Evolve

    route Aikido.Identity.Signals.UpdateProfile,
          Aikido.Identity.Actions.UpdateProfile
  end
end
