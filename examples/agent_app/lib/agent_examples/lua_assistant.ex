defmodule AgentExamples.LuaAssistant do
  @moduledoc "Application-owned Lua entrypoint selection with native actor and tenant propagation."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "lua_assistant"
    persistence :temporary
  end

  ai do
    system_prompt "Use scoped_lua_docs to discover the currently available Lua functions. When the user supplies a Lua script, execute it using scoped_lua and report the actual result. A request for docs should call scoped_lua_docs. Do not invent results or unavailable functions."
  end
end
