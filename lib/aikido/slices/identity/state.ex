defmodule Aikido.Slices.Identity.State do
  @moduledoc """
  A first-class agent primitive representing who the agent is.

  Identity is stored at the `:identity` key in agent state and captures
  lifecycle facts (profile).

  Identity is immutable — updates produce a new struct with a bumped revision.
  """

  use Ash.TypedStruct

  typed_struct do
    field :rev, :integer, allow_nil?: false, default: 0, description: "Monotonic revision"
    field :profile, :map, allow_nil?: false, default: %{age: nil}, description: "Lifecycle facts"
    field :created_at, :integer, allow_nil?: false, description: "Creation timestamp (ms)"
    field :updated_at, :integer, allow_nil?: false, description: "Last update timestamp (ms)"
  end

  @schema __MODULE__
  defoverridable new!: 1
  def new!(value) do
    value
    |> then(&Ash.Type.cast_input(__MODULE__, &1))
    |> Ash.Helpers.unwrap_or_raise!()
  end

  defoverridable cast_input: 2
  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints) do
    values = Map.merge(Map.from_struct(struct(__MODULE__)), Map.new(value))
    Ash.Type.apply_constraints(:struct, values, __MODULE__.subtype_constraints())
  end

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Identity."
  @spec schema() :: Ash.Type.t()
  def schema, do: @schema

  @doc "Create a new identity"
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    %__MODULE__{
      rev: 0,
      profile: opts[:profile] || %{age: nil},
      created_at: now,
      updated_at: now
    }
  end

  @doc "Pure evolution — increments age and bumps revision"
  @spec evolve(t(), keyword()) :: t()
  def evolve(%__MODULE__{} = identity, opts \\ []) do
    years = opts[:years] || 0
    days = opts[:days] || 0
    now = opts[:now] || System.system_time(:millisecond)
    age_increment = years + div(days, 365)
    current_age = identity.profile[:age] || 0

    %{
      identity
      | profile: Map.put(identity.profile, :age, current_age + age_increment)
    }
    |> bump(now: now)
  end

  @doc """
  Merges `profile_updates` into the identity's profile and bumps the
  revision. Existing keys in the profile are preserved when not present in
  `profile_updates`.
  """
  @spec update_profile(t(), map(), keyword()) :: t()
  def update_profile(%__MODULE__{} = identity, profile_updates, opts \\ [])
      when is_map(profile_updates) do
    %{identity | profile: Map.merge(identity.profile, profile_updates)}
    |> bump(opts)
  end

  @doc "Return a public snapshot of the identity"
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = identity) do
    %{
      profile: Map.take(identity.profile, [:age, :generation, :origin])
    }
  end

  @doc "Bump identity revision and updated_at timestamp"
  @spec bump(t(), keyword()) :: t()
  def bump(%__MODULE__{} = identity, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)
    %{identity | rev: identity.rev + 1, updated_at: now}
  end
end
