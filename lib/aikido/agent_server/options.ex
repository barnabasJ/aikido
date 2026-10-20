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

  @type on_parent_death :: :stop | :continue | :emit_orphan

  use Ash.TypedStruct

  typed_struct do
    field :agent_module, :module,
      allow_nil?: false,
      constraints: [behaviour: Aikido.Agent],
      description: "Agent module; required. Initialized through its :initialize Ash action."

    field :aikido, :atom,
      allow_nil?: false,
      default: Aikido.Default,
      description: "Aikido instance name for DurableServer scoping (default: Aikido.Default)"

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition within a Aikido instance"

    field :id, :string,
      allow_nil?: false,
      description: "Instance ID (auto-generated if not provided)",
      constraints: [trim?: false, allow_empty?: true]

    field :initial_state, :map,
      allow_nil?: false,
      default: %{},
      description: "Initial agent state"

    field :middleware, {:array, :term},
      allow_nil?: false,
      default: [],
      description:
        "Runtime-appended middleware modules. Each entry is a bare module or {Mod, opts_map}."

    field :parent, ParentRef, allow_nil?: true, description: "Parent reference for hierarchy"

    field :on_parent_death, :atom,
      allow_nil?: false,
      default: :stop,
      description: "Behavior when parent dies",
      constraints: [one_of: [:stop, :continue, :emit_orphan]]

    field :skip_schedules, :boolean,
      allow_nil?: false,
      default: false,
      description: "Skip registering slice schedules (useful for tests)"

    field :durable_server, :atom,
      allow_nil?: true,
      description: "Owning DurableServer supervisor"

    field :durable_key, :term,
      allow_nil?: true,
      description: "Logical DurableServer identity"

    field :debug, :boolean,
      allow_nil?: false,
      default: false,
      description: "Enable debug mode with event buffer"
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
