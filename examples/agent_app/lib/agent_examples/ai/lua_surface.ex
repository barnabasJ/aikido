defmodule AgentExamples.AI.LuaSurface do
  @moduledoc "AshLua's generated eval/docs actions, exposed to the model through Ash AI."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [AshLua.EvalActions]

  actions do
    action :eval, :map do
      description "Run Lua against the scoped AshLua surface, preserving structured errors in tool responses."
      argument :script, :string, allow_nil?: false
      run AgentExamples.AI.LuaSurface.Actions.Evaluate
    end
  end

  eval_actions do
    otp_app :agent_examples
    labels [:analysis, :agents]
  end
end
