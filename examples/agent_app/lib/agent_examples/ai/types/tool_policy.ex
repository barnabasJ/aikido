defmodule AgentExamples.AI.Types.ToolPolicy do
  @moduledoc "How an example exposes model tools and whether Lua scripting is selectable."
  use Ash.Type.Enum,
    values: [
      optional_lua: "Direct tools with an optional Lua scripting surface.",
      required_lua: "Lua tools required by the example's workflow and prompts.",
      fixed: "Tools owned by the example or its application preparation action."
    ]
end
