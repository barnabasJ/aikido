defmodule AgentExamples.LuaAssistant.Tools.ReportScope do
  @moduledoc "Reports the native actor and tenant received by an inner Lua-invoked Ash action."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, context), do: {:ok, %{actor: context.actor, tenant: context.tenant}}
end
