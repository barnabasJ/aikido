defmodule Aikido.Agent.Errors.ExecutionIdentityRequiresRestart do
  @moduledoc "The supplied actor or tenant differs from this activation's authenticated identity."
  use Splode.Error, class: :forbidden, fields: []

  def message(_error) do
    "The caller's actor or tenant differs from this agent's authenticated execution identity. " <>
      "Use the matching caller scope, or stop and restart the agent with the intended identity. " <>
      "Changing saved identity attributes does not change a running activation."
  end
end

defimpl AshAi.ToToolError, for: Aikido.Agent.Errors.ExecutionIdentityRequiresRestart do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Agent.Errors.ExecutionIdentityRequiresRestart do
  def to_error(error) do
    %{
      code: "execution_identity_requires_restart",
      message: Exception.message(error),
      short_message: "Execution identity requires restart",
      fields: [],
      vars: %{}
    }
  end
end
