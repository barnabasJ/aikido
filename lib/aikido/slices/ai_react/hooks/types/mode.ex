defmodule Aikido.Slices.AiReact.Hooks.Types.Mode do
  @moduledoc "Whether a Lua hook gates a step or observes independently."
  use Ash.Type.Enum,
    values: [
      sync: "Wait for the hook before continuing the step.",
      async: "Run the hook without delaying the step."
    ]
end
