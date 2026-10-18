defmodule AgentExamples.AI.LuaSurface do
  @moduledoc "AshLua's generated eval/docs actions, exposed to the model through Ash AI."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [AshLua.EvalActions]

  eval_actions do
    otp_app :agent_examples
    labels [:analysis, :agents]
  end
end
