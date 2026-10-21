defmodule Aikido.AiReact.Types.TerminalStatus do
  @moduledoc "Terminal run outcomes held while lifecycle hooks finish."
  use Ash.Type.Enum,
    values: [
      completed: "The run completed.",
      failed: "The run failed or was cancelled."
    ]
end
