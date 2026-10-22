defmodule AgentExamples.Quicksort.Types.Status do
  @moduledoc "Lifecycle of one quicksort partition."
  use Ash.Type.Enum,
    values: [
      idle: "Awaiting input",
      sorting: "Waiting for child partitions",
      completed: "Partition sorted"
    ]
end
