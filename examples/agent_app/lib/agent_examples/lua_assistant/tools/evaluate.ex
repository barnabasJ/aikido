defmodule AgentExamples.LuaAssistant.Tools.Evaluate do
  @moduledoc "Runs AshLua with the app's selected entrypoints and native caller scope."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, context) do
    options = AgentExamples.LuaAssistant.Tools.vm_options(input.context)

    AshLua.Eval.run(
      input.arguments.script,
      options ++ Ash.Scope.to_opts(context, context: input.context)
    )
  end
end
