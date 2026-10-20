defmodule Aikido.AgentServer.ChildInfo do
  @moduledoc """
  Information about a child agent in the logical hierarchy.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice.

  Used for parent agents to track spawned children.
  """

  use Ash.TypedStruct

  typed_struct do
    field :pid, :term, allow_nil?: false, description: "Child process PID"
    field :ref, :term, allow_nil?: false, description: "Monitor reference for the child process"
    field :module, :atom, allow_nil?: false, description: "Child agent module"

    field :id, :string,
      allow_nil?: false,
      description: "Child instance ID",
      constraints: [trim?: false, allow_empty?: true]

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition of the child agent"

    field :tag, :term, allow_nil?: true, description: "Tag used when spawning"

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Metadata passed during spawn"
  end

  @type t :: %__MODULE__{}
end
