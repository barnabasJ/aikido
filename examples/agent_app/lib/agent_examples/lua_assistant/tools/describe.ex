defmodule AgentExamples.LuaAssistant.Tools.Describe do
  @moduledoc "Documents exactly the Lua entrypoints that this caller can execute."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context),
    do:
      input.context
      |> AgentExamples.LuaAssistant.Tools.vm_options()
      |> AshLua.Eval.docs(name: "full")
end
