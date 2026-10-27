defmodule AgentExamples.LuaAssistant.Tools.Evaluate do
  @moduledoc "Runs AshLua with the app's selected entrypoints and native caller scope."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, context) do
    options = AgentExamples.LuaAssistant.Tools.vm_options(input.context)

    with {:ok, result} <-
           AshLua.Eval.run(
             input.arguments.script,
             options ++ Ash.Scope.to_opts(context, context: input.context)
           ) do
      AgentExamples.AI.Errors.LuaScriptFailed.reject_script_error(result)
    end
  end
end
