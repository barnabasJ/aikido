defmodule Aikido.AgentServer.Signal.ChildStarted do
  @moduledoc """
  Emitted by a child agent when it finishes initialization and becomes ready.

  Delivered to the parent as `aikido.agent.child.started`. This allows the parent
  to know when a spawned child is ready to receive signals.

  ## Fields

  - `:parent_id` - ID of the parent agent
  - `:child_id` - ID of the child agent
  - `:child_partition` - Partition of the child agent
  - `:child_module` - Module of the child agent
  - `:tag` - Tag used when spawning the child
  - `:pid` - PID of the child process
  - `:meta` - Metadata passed during spawn
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.child.started"
    source "/agent"

    schema do
      attribute :parent_id, :string, allow_nil?: false, description: "ID of the parent agent"
      attribute :child_id, :string, allow_nil?: false, description: "ID of the child agent"
      attribute :child_partition, :term, description: "Partition of the child agent"
      attribute :child_module, :term, allow_nil?: false, description: "Module of the child agent"
      attribute :tag, :term, allow_nil?: false, description: "Tag used when spawning"
      attribute :pid, :term, allow_nil?: false, description: "PID of the child process"
      attribute :meta, :map, default: %{}, description: "Metadata passed during spawn"
    end
  end
end
