defmodule AgentExamples.Worker.Types.Status do
  @moduledoc "Lifecycle states of the example background worker."
  use Ash.Type.Enum,
    values: [
      idle: "The worker has no active job.",
      working: "Background work is in progress.",
      completed: "The job completed successfully.",
      failed: "The job failed."
    ]
end
