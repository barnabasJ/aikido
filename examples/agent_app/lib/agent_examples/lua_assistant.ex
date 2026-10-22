defmodule AgentExamples.LuaAssistant do
  @moduledoc "Application-owned Lua entrypoint selection with native actor and tenant propagation."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "lua_assistant"
    persistence :temporary
  end
end
