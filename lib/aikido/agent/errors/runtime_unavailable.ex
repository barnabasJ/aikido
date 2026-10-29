defmodule Aikido.Agent.Errors.RuntimeUnavailable do
  @moduledoc """
  An external command could not access the agent runtime.

  `reason` retains the original exit term, or `:not_running` for an absent
  identity. It may contain private request data; inspect and tool projections
  deliberately omit it. This error alone does not establish retry safety or
  process death: a runtime call can also time out.
  """
  use Splode.Error, class: :invalid, fields: [:reason]

  def message(_error), do: "Agent runtime unavailable while processing the command."
end

defimpl Inspect, for: Aikido.Agent.Errors.RuntimeUnavailable do
  def inspect(_error, _opts), do: "#Aikido.Agent.Errors.RuntimeUnavailable<reason: [redacted]>"
end

defimpl AshAi.ToToolError, for: Aikido.Agent.Errors.RuntimeUnavailable do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Agent.Errors.RuntimeUnavailable do
  def to_error(error) do
    %{
      code: "agent_runtime_unavailable",
      message: Exception.message(error),
      short_message: "Agent runtime unavailable",
      fields: [],
      vars: %{}
    }
  end
end
