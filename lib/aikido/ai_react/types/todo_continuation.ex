defmodule Aikido.AiReact.Types.TodoContinuation do
  @moduledoc "How a ReAct run responds when blocking todos remain after an answer."
  use Ash.Type.Enum,
    values: [
      wait: "Wait for external work or messages.",
      continue: "Ask the model to continue with the remaining work.",
      nudge_once: "Remind an idle answer once before failing unresolved blocking work."
    ]
end
