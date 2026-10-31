defmodule Aikido.Team.Errors.OperationFailed do
  @moduledoc """
  A topology operation failed without a recognized public validation reason.

  `reason` retains the original cause for internal diagnostics. Its contents are
  omitted from inspection and tool projections. This error does not establish
  whether the requested member started or stopped, or whether retrying is safe.
  """
  use Splode.Error, class: :invalid, fields: [:reason]

  def message(_error) do
    "The team lifecycle operation failed. Inspect member status and runtime logs before retrying; " <>
      "do not assume the requested member was started or stopped."
  end
end

defimpl Inspect, for: Aikido.Team.Errors.OperationFailed do
  def inspect(_error, _opts), do: "#Aikido.Team.Errors.OperationFailed<reason: [redacted]>"
end

defimpl AshAi.ToToolError, for: Aikido.Team.Errors.OperationFailed do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Team.Errors.OperationFailed do
  def to_error(error) do
    %{
      code: "team_operation_failed",
      message: Exception.message(error),
      short_message: "Team operation failed",
      fields: [],
      vars: %{}
    }
  end
end
