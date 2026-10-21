defmodule Aikido.AiReact.Hooks.Types.Event do
  @moduledoc "Lifecycle events that can trigger a Lua hook."
  use Ash.Type.Enum,
    values: [
      run_started: "The run has been accepted.",
      before_model: "Before dispatching a model request.",
      after_model: "After adopting a model response.",
      before_tool: "Before dispatching a tool call.",
      after_tool: "After adopting a tool result.",
      run_completed: "The run reached completion.",
      run_failed: "The run failed.",
      run_cancelled: "The run was cancelled."
    ]
end
