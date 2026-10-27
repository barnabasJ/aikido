defmodule AgentExamples.AI.LuaSurface.Tools.RunScript do
  @moduledoc "Adapts native AshLua evaluation errors to the model-facing tool failure contract."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    scope = Ash.Scope.to_opts(context, context: input.context)

    with {:ok, result} <-
           input.resource
           |> Ash.ActionInput.for_action(:eval, %{script: input.arguments.script}, scope)
           |> Ash.run_action(scope) do
      AgentExamples.AI.Errors.LuaScriptFailed.reject_script_error(result)
    end
  end
end
