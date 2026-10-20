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
    field :pid, :term do
      allow_nil? false
      description "Child process PID"
    end

    field :ref, :term do
      allow_nil? false
      description "Monitor reference for the child process"
    end

    field :module, :atom do
      allow_nil? false
      description "Child agent module"
    end

    field :id, :string do
      allow_nil? false
      description "Child instance ID"
      constraints trim?: false, allow_empty?: true
    end

    field :partition, :term do
      allow_nil? true
      description "Logical partition of the child agent"
    end

    field :tag, :term do
      allow_nil? true
      description "Tag used when spawning"
    end

    field :meta, :map do
      allow_nil? false
      default %{}
      description "Metadata passed during spawn"
    end
  end

  @type t :: %__MODULE__{}
end
