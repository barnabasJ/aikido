defmodule AgentExamples.Quicksort.Types.Status do
  @moduledoc "Lifecycle of one quicksort partition."
  use Ash.Type.Enum,
    values: [
      idle: "Awaiting input",
      sorting: "Waiting for child partitions",
      completed: "Partition sorted",
      failed: "A child could not start or exited before returning its result"
    ]
end
