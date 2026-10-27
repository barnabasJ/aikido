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

  def from_reason(%{__struct__: module} = error)
      when module in [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Framework],
      do: error

  def from_reason(%{__exception__: true} = error) do
    if AshAi.ToToolError.impl_for(error) && AshLua.Error.impl_for(error) do
      error
    else
      failure(
        "team_operation_failed",
        "The team operation failed with #{inspect(error.__struct__)} without a public diagnostic.",
        "Inspect the worker and runtime diagnostics, correct the cause, and check whether earlier effects completed before retrying. Do not repeat the same call unchanged."
      )
    end
  end

  def from_reason(_reason) do
    failure(
      "team_operation_failed",
      "The team operation returned a runtime failure without a public diagnostic.",
      "Inspect agents.members and the task or worker state. Ensure the intended worker is running, check completed effects, and correct the cause before retrying."
    )
  end

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
