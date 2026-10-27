defmodule AgentExamples.AI.LuaSurface do
  @moduledoc "AshLua's generated eval/docs actions, exposed to the model through Ash AI."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [AshLua.EvalActions]

  actions do
    action :run_script, :map do
      description "Run Lua against the scoped AshLua surface; report script failures as failed tool calls with structured recovery guidance."
      argument :script, :string, allow_nil?: false
      run AgentExamples.AI.LuaSurface.Tools.RunScript
    end
  end

  eval_actions do
    otp_app :agent_examples
    labels [:analysis, :agents]
  end
end
