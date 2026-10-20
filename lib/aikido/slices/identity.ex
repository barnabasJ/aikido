defmodule Aikido.Slices.Identity do
  @moduledoc """
  Identity slice — owns the `:identity` key in agent state, mounted as a
  `%Aikido.Slices.Identity{}` self-model.

  ## State shape

  Declared by the embedded resource attributes. Mounted slices are initialized
  through their native create action before receiving signals. Reducers require
  the initialized resource struct and retain native Ash type validation.

  ## Routes

      route Aikido.Signals.Identity.Ensure, Aikido.Slices.Identity.Implementation
      route Aikido.Signals.Identity.Evolve, Aikido.Slices.Identity.Implementation
      route Aikido.Signals.Identity.UpdateProfile, Aikido.Slices.Identity.Implementation

  Mount with `slice :identity, Aikido.Slices.Identity` inside an agent resource.

  """

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "identity"
    description "Identity self-model for agent (lifecycle facts, profile)."

    schema do
      attribute :rev, :integer,
        public?: true,
        allow_nil?: false,
        default: 0,
        description: "Monotonic revision"

      attribute :profile, :map,
        public?: true,
        allow_nil?: false,
        default: %{age: nil},
        description: "Lifecycle facts"

      attribute :created_at, :integer,
        default: 0,
        public?: true,
        allow_nil?: false,
        description: "Creation timestamp (ms)"

      attribute :updated_at, :integer,
        default: 0,
        public?: true,
        allow_nil?: false,
        description: "Last update timestamp (ms)"
    end

    route Aikido.Signals.Identity.Ensure, Aikido.Slices.Identity.Implementation
    route Aikido.Signals.Identity.Evolve, Aikido.Slices.Identity.Implementation
    route Aikido.Signals.Identity.UpdateProfile, Aikido.Slices.Identity.Implementation
  end

  @type t :: map()

  @doc "Create a new identity"
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    struct!(__MODULE__,
      rev: 0,
      profile: opts[:profile] || %{age: nil},
      created_at: now,
      updated_at: now
    )
  end

  @doc "Pure evolution — increments age and bumps revision"
  @spec evolve(t(), keyword()) :: t()
  def evolve(%{__struct__: __MODULE__} = identity, opts \\ []) do
    years = opts[:years] || 0
    days = opts[:days] || 0
    now = opts[:now] || System.system_time(:millisecond)
    age_increment = years + div(days, 365)
    current_age = identity.profile[:age] || 0

    %{identity | profile: Map.put(identity.profile, :age, current_age + age_increment)}
    |> bump(now: now)
  end

  @doc """
  Merges `profile_updates` into the identity's profile and bumps the
  revision. Existing keys in the profile are preserved when not present in
  `profile_updates`.
  """
  @spec update_profile(t(), map(), keyword()) :: t()
  def update_profile(%{__struct__: __MODULE__} = identity, profile_updates, opts \\ [])
      when is_map(profile_updates) do
    %{identity | profile: Map.merge(identity.profile, profile_updates)} |> bump(opts)
  end

  @doc "Bump identity revision and updated_at timestamp"
  @spec bump(t(), keyword()) :: t()
  def bump(%{__struct__: __MODULE__} = identity, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)
    %{identity | rev: identity.rev + 1, updated_at: now}
  end
end
