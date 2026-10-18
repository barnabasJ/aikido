defmodule Aikido.Slices.Memory do
  @moduledoc """
  Memory slice — owns the `:memory` key in agent state, mounted as a
  `%Aikido.Slices.Memory.State{}` value with named map / list spaces.

  ## State shape

  Bound to `Aikido.Slices.Memory.State.schema/0`. The slice starts as `nil` (lazy-init);
  the first inbound `aikido.memory.*` signal materializes a fresh
  `%Aikido.Slices.Memory.State{}` via the relevant action.

  ## Routes

  Each `aikido.memory.*` signal type maps to a single action under
  `Aikido.Slices.Memory.Actions.*`:

      # ensure / put / update / delete
      route "aikido.memory.ensure",            Actions.Ensure
      route "aikido.memory.put_space",         Actions.PutSpace
      route "aikido.memory.update_space",      Actions.UpdateSpace
      route "aikido.memory.ensure_space",      Actions.EnsureSpace
      route "aikido.memory.delete_space",      Actions.DeleteSpace

      # map space ops
      route "aikido.memory.put_in_space",      Actions.PutInSpace
      route "aikido.memory.delete_from_space", Actions.DeleteFromSpace

      # list space ops
      route "aikido.memory.append_to_space",   Actions.AppendToSpace

  ## Default slice

  This slice is automatically included as a default slice for all agents
  unless explicitly disabled:

      use Aikido.Agent, default_slices: %{memory: false}

      agent do
        name "minimal"
      end

  ## Persistence

  This bare-minimum default slice keeps memory in-process only and does not
  externalize on checkpoint. If you need a persistence transform, implement
  your own slice that declares `@behaviour Aikido.Persist.Transform` and
  override `default_slices: %{memory: MyApp.MyMemorySlice}`.
  """

  alias Aikido.Slices.Memory.Actions
  alias Aikido.Slices.Memory.State

  use Aikido.Slice

  slice do
    name "memory"
    description "Memory state for agent cognition — named map / list spaces."

    schema do
      attribute :id, :string,
        allow_nil?: false,
        description: "Unique memory identifier",
        constraints: [trim?: false, allow_empty?: true]

      attribute :rev, :integer,
        allow_nil?: false,
        default: 0,
        description: "Container-level monotonic revision"

      attribute :spaces, :map,
        allow_nil?: false,
        default: %{},
        description: "Open map of named spaces"

      attribute :created_at, :integer, allow_nil?: false, description: "Creation timestamp (ms)"

      attribute :updated_at, :integer,
        allow_nil?: false,
        description: "Last update timestamp (ms)"

      attribute :metadata, :map,
        allow_nil?: false,
        default: %{},
        description: "Arbitrary metadata"
    end

    state_transform {Aikido.Schema, :to_struct, [State]}
  end

  signal_routes do
    route "aikido.memory.ensure", Actions.Ensure
    route "aikido.memory.put_space", Actions.PutSpace
    route "aikido.memory.update_space", Actions.UpdateSpace
    route "aikido.memory.ensure_space", Actions.EnsureSpace
    route "aikido.memory.delete_space", Actions.DeleteSpace
    route "aikido.memory.put_in_space", Actions.PutInSpace
    route "aikido.memory.delete_from_space", Actions.DeleteFromSpace
    route "aikido.memory.append_to_space", Actions.AppendToSpace
  end

  capabilities do
    capability :memory
  end

  @memory_section %Spark.Dsl.Section{
    name: :memory,
    describe: "Configuration block contributed by Aikido.Slices.Memory.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@memory_section],
    transformers: [Aikido.Slices.Memory.Transformers.RegisterContribution]
end
