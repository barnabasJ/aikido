defmodule Aikido.AgentServer.ParentRef do
  @moduledoc """
  Reference to a logical parent agent in Aikido hierarchy tracking.

  `ParentRef` models Aikido's logical parent-child relationship, which is layered
  on top of OTP supervision. Parent and child agents are still OTP peers under
  a supervisor; the parent relationship is represented explicitly with this
  struct, child-start signals, and process monitors.

  The current parent ref lives on `%Aikido.AgentServer.State{}` (under
  `:parent`) and is exposed to actions in `input.context.aikido.parent`. When a
  child becomes orphaned, the runtime moves the former parent to
  `state.orphaned_from` and emits identity-transition signals
  (`aikido.agent.identity.parent_died` / `aikido.agent.identity.orphaned`).
  """

  use Ash.TypedStruct

  typed_struct do
    field :pid, :term, allow_nil?: false, description: "Parent process PID"

    field :id, :string,
      allow_nil?: false,
      description: "Parent instance ID",
      constraints: [trim?: false, allow_empty?: true]

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition of the parent agent"

    field :tag, :term,
      allow_nil?: false,
      description: "Tag assigned by parent when spawning this child"

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Arbitrary metadata from parent"
  end

  @type t :: %__MODULE__{}
end
