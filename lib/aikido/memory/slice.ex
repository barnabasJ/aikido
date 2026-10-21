defmodule Aikido.Memory.Slice do
  @moduledoc """
  Memory slice — owns the `:memory` key in agent state, mounted as a
  `%Aikido.Memory.Slice{}` value with named map / list spaces.

  ## State shape

  Declared by the embedded resource attributes. Mounted slices are initialized
  through their native create action before receiving signals. Reducers require
  the initialized resource struct and retain native Ash type validation.

  ## Routes

  Each `aikido.memory.*` signal type maps to a native action on
  `Aikido.Memory.Slice`:

      # ensure / put / update / delete
      route Aikido.Memory.Signals.Ensure, Aikido.Memory.Actions.Ensure
      route Aikido.Memory.Signals.PutSpace, Aikido.Memory.Actions.PutSpace
      route Aikido.Memory.Signals.UpdateSpace, Aikido.Memory.Actions.UpdateSpace
      route Aikido.Memory.Signals.EnsureSpace, Aikido.Memory.Actions.EnsureSpace
      route Aikido.Memory.Signals.DeleteSpace, Aikido.Memory.Actions.DeleteSpace

      # map space ops
      route Aikido.Memory.Signals.PutInSpace, Aikido.Memory.Actions.PutInSpace
      route Aikido.Memory.Signals.DeleteFromSpace, Aikido.Memory.Actions.DeleteFromSpace

      # list space ops
      route Aikido.Memory.Signals.AppendToSpace, Aikido.Memory.Actions.AppendToSpace

  Mount with `slice :memory, Aikido.Memory.Slice` inside an agent resource.

  ## Persistence

  DurableServer snapshots retain the complete memory state. For a custom
  serialized representation, implement
  your own slice that declares `@behaviour Aikido.Durable.Codec` and
  mount that custom resource instead.
  """

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension]

  slice do
    name "memory"
    description "Memory state for agent cognition — named map / list spaces."

    schema do
      attribute :id, :string do
        description "Memory identifier within the owning agent"
        default "memory"
        public? true
        allow_nil? false
        constraints trim?: false, allow_empty?: true
      end

      attribute :rev, :integer do
        description "Container-level monotonic revision"
        public? true
        allow_nil? false
        default 0
      end

      attribute :spaces, :map do
        description "Open map of named spaces"
        public? true
        allow_nil? false

        default %{
          world: %Aikido.Memory.Types.Space{data: %{}},
          tasks: %Aikido.Memory.Types.Space{data: []}
        }
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

      attribute :metadata, :map do
        description "Arbitrary metadata"
        public? true
        allow_nil? false
        default %{}
      end
    end

    route Aikido.Memory.Signals.Ensure, Aikido.Memory.Actions.Ensure
    route Aikido.Memory.Signals.PutSpace, Aikido.Memory.Actions.PutSpace
    route Aikido.Memory.Signals.UpdateSpace, Aikido.Memory.Actions.UpdateSpace
    route Aikido.Memory.Signals.EnsureSpace, Aikido.Memory.Actions.EnsureSpace
    route Aikido.Memory.Signals.DeleteSpace, Aikido.Memory.Actions.DeleteSpace
    route Aikido.Memory.Signals.PutInSpace, Aikido.Memory.Actions.PutInSpace

    route Aikido.Memory.Signals.DeleteFromSpace,
          Aikido.Memory.Actions.DeleteFromSpace

    route Aikido.Memory.Signals.AppendToSpace, Aikido.Memory.Actions.AppendToSpace
  end
end
