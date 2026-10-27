defmodule AgentExamples.LuaAssistant.Tools do
  @moduledoc "Native Ash tools whose execution and documentation share the same application-selected Lua surface."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [AshLua.Resource]

  lua do
    name "scoped_tools"
  end

  actions do
    action :eval, :map do
      argument :script, :string, allow_nil?: false
      run AgentExamples.LuaAssistant.Tools.Evaluate
    end

    action :docs, :string do
      run AgentExamples.LuaAssistant.Tools.Describe
    end

    action :whoami, :map do
      run AgentExamples.LuaAssistant.Tools.ReportScope
    end
  end

  @doc "Resolve the exact Lua entrypoints from declarative application context for both eval and docs."
  def vm_options(context) do
    allowed = get_in(context, [:shared, :allow_scope]) == true

    [
      otp_app: :agent_examples,
      action_entrypoints: if(allowed, do: [{__MODULE__, :whoami}], else: [])
    ]
  end
end
