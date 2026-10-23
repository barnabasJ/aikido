defmodule AgentExamples.AI.Tools.DelegationFailed do
  @moduledoc "Known, credential-redacted failure returned by a delegated AI assignment."
  use Splode.Error, fields: [:message], class: :invalid
end

defimpl AshAi.ToToolError, for: AgentExamples.AI.Tools.DelegationFailed do
  def to_tool_error(error), do: error.message
end

defimpl AshLua.Error, for: AgentExamples.AI.Tools.DelegationFailed do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: "delegation_failed",
      fields: [],
      vars: %{}
    }
  end
end
