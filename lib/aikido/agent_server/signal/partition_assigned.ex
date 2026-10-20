defmodule Aikido.AgentServer.Signal.PartitionAssigned do
  @moduledoc """
  Emitted by the AgentServer once its logical partition is established.

  Delivered as `aikido.agent.identity.partition_assigned` shortly after
  `State.from_options/3` returns. Routed through the same signal pipeline as
  any other lifecycle signal so slices and middleware can observe it.

  ## Fields

  - `:partition` - The logical partition the AgentServer was assigned to,
    or `nil` if the agent runs un-partitioned.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.identity.partition_assigned"

    schema do
      attribute :partition, :term, description: "Logical partition or nil"
    end
  end
end
