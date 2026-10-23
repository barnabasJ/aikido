defmodule Aikido.AgentServer.Options do
  @moduledoc """
  Options for starting an AgentServer.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice.

  Validates and normalizes startup options including agent configuration,
  hierarchy settings and middleware configuration.
  """

  alias Aikido.AgentServer.ParentRef

  @type on_parent_death :: Aikido.AgentServer.Types.ParentDeathPolicy.t()

  use Ash.TypedStruct

  typed_struct do
    field :sync, Aikido.Durable.SyncPolicy do
      description "DurableServer synchronization policy used by this agent and inherited by spawned children."
      default %Aikido.Durable.SyncPolicy{}
      allow_nil? false
    end

    field :agent_module, :module do
      allow_nil? false
      constraints behaviour: Aikido.Agent
      description "Agent module; required. Initialized through its :initialize Ash action."
    end

    field :aikido, :atom do
      allow_nil? false
      default Aikido.Default
      description "Aikido instance name for DurableServer scoping (default: Aikido.Default)"
    end

    field :partition, :term do
      allow_nil? true
      description "Logical partition within a Aikido instance"
    end

    field :id, :string do
      allow_nil? false
      description "Instance ID (auto-generated if not provided)"
      constraints trim?: false, allow_empty?: true
    end

    field :initial_state, :map do
      allow_nil? false
      default %{}
      description "Initial own-state and mounted slice values supplied to native initialization."
    end

    field :middleware, {:array, :term} do
      allow_nil? false
      default []

      description "Runtime-appended middleware modules. Each entry is a bare module or {Mod, opts_map}."
    end

    field :parent, ParentRef do
      allow_nil? true
      description "Parent reference for hierarchy"
    end

    field :on_parent_death, Aikido.AgentServer.Types.ParentDeathPolicy do
      allow_nil? false
      default :stop
      description "Behavior when parent dies"
    end

    field :skip_schedules, :boolean do
      allow_nil? false
      default false
      description "Skip registering slice schedules (useful for tests)"
    end

    field :durable_server, :atom do
      allow_nil? true
      description "Owning DurableServer supervisor"
    end

    field :durable_key, :term do
      allow_nil? true
      description "Logical DurableServer identity"
    end

    field :debug, :boolean do
      allow_nil? false
      default false
      description "Enable debug mode with event buffer"
    end
  end

  @type t :: %__MODULE__{}

  @doc "Creates typed startup options, generating an identity when omitted."
  def new(attrs) do
    attrs = if is_struct(attrs, __MODULE__), do: Map.from_struct(attrs), else: Map.new(attrs)
    # Ash.TypedStruct defaults are literal values; runtime ID generation belongs here.
    attrs =
      if Map.get(attrs, :id, attrs["id"]) in [nil, ""],
        do: Map.put(attrs, :id, Ash.UUIDv7.generate()),
        else: attrs

    super(attrs)
  end
end
