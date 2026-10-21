defmodule Aikido.Slices.AiReact.Types.Status do
  @moduledoc "Lifecycle stages of a ReAct run."
  use Ash.Type.Enum,
    values: [
      idle: "No run has started.",
      setup: "Hooks and tools are being prepared.",
      running: "Model, tool or hook work is in progress.",
      waiting: "A model answer is waiting for required todos.",
      completed: "The run has completed.",
      failed: "The run failed or was cancelled."
    ]
end
