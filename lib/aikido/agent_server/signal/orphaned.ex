defmodule Aikido.AgentServer.Signal.Orphaned do
  @moduledoc """
  Emitted when a child survives logical parent death and becomes orphaned.

  Delivered to the child itself as `aikido.agent.orphaned` after the runtime has
  already cleared the current parent reference. This lets child actions make
  decisions using the former-parent snapshot without accidentally treating the
  dead parent as still attached.

  ## Fields

  - `:parent_id` - ID of the former parent agent
  - `:parent_pid` - PID of the former parent process
  - `:tag` - Tag the former parent used for this child
  - `:meta` - Former parent metadata from the child's prior `ParentRef`
  - `:reason` - Exit reason from the former parent process
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.orphaned"

    schema do
      attribute :parent_id, :string,
        allow_nil?: false,
        description: "ID of the parent agent that died"

      attribute :parent_pid, :term,
        allow_nil?: false,
        description: "PID of the parent process that died"

      attribute :tag, :term, allow_nil?: false, description: "Tag assigned by the former parent"

      attribute :meta, :map,
        default: %{},
        description: "Metadata copied from the former parent reference"

      attribute :reason, :term,
        allow_nil?: false,
        description: "Exit reason from the parent process"
    end
  end
end
