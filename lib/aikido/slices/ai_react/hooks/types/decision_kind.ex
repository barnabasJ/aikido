defmodule Aikido.Slices.AiReact.Hooks.Types.DecisionKind do
  @moduledoc "Decisions returned by a synchronous Lua hook."
  use Ash.Type.Enum,
    values: [
      continue: "Allow the held step to proceed.",
      deny: "Reject the held step and fail the run."
    ]
end
