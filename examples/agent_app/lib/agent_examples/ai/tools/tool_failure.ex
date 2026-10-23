defmodule AgentExamples.AI.Tools.ToolFailure do
  @moduledoc "Recoverable team-tool failures rendered through native Ash AI and AshLua error protocols."
  use Splode.Error, fields: [:message, :code, :recovery], class: :invalid

  def from_reason(%__MODULE__{} = error), do: error

  def from_reason(:operation_in_progress),
    do:
      failure(
        "operation_in_progress",
        "A team topology operation is still in progress.",
        "Wait for the current spawn or stop operation to finish before delegating."
      )

  def from_reason(:timeout),
    do:
      failure(
        "deadline_exceeded",
        "Delegated work exceeded its remaining deadline.",
        "Do not retry with the expired budget. Report partial findings or request a new run with a smaller task or larger budget."
      )

  def from_reason(:cancelled),
    do:
      failure(
        "cancelled",
        "The assignment was cancelled.",
        "Do not retry automatically; wait for a new assignment."
      )

  def from_reason(reason) when is_binary(reason),
    do:
      failure(
        "assignment_failed",
        reason,
        "Correct the reported cause before retrying. Inspect agents.members when selecting a worker; report persistent provider failures to the user."
      )

  def from_reason(reason), do: reason

  def failure(code, message, recovery),
    do: exception(code: code, message: message, recovery: recovery)

  def describe(error), do: "#{error.code}: #{error.message} #{error.recovery}"
end

defimpl AshAi.ToToolError, for: AgentExamples.AI.Tools.ToolFailure do
  def to_tool_error(error), do: AgentExamples.AI.Tools.ToolFailure.describe(error)
end

defimpl AshLua.Error, for: AgentExamples.AI.Tools.ToolFailure do
  def to_error(error) do
    %{
      message: AgentExamples.AI.Tools.ToolFailure.describe(error),
      short_message: error.message,
      code: error.code,
      fields: [],
      vars: %{recovery: error.recovery}
    }
  end
end
