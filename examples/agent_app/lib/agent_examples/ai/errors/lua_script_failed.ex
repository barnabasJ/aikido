defmodule AgentExamples.AI.Errors.LuaScriptFailed do
  @moduledoc "A native Lua evaluation failure with its public error details and recovery instructions."
  use Splode.Error, fields: [:details], class: :invalid

  @doc "Keep successful eval data, or convert its native error envelope to a typed tool failure."
  def reject_script_error(%{error: nil} = result), do: {:ok, result}
  def reject_script_error(%{error: error}), do: {:error, exception(details: error)}

  def message(error), do: tool_error_json(error)

  @doc "Encode the public Lua error and recovery guidance without exception breadcrumbs."
  def tool_error_json(error) do
    Jason.encode!(%{
      error: error.details |> AshLua.Encoder.encode_result() |> explain_opaque_errors(),
      code: "lua_script_failed",
      recovery:
        "Read the returned error details and lua_docs, correct the script or action inputs, and inspect target state before repeating side effects. Do not retry the same script unchanged."
    })
  end

  defp explain_opaque_errors(%{"errors" => errors} = envelope) do
    Map.put(envelope, "errors", Enum.map(errors, &explain_opaque_error/1))
  end

  defp explain_opaque_errors(error), do: error

  defp explain_opaque_error(%{"code" => "unknown_error"} = error) do
    Map.update!(error, "message", fn message ->
      message <>
        " The action did not expose a recoverable error. Inspect the roster or target state, use another supported action, or report this reference to the operator."
    end)
  end

  defp explain_opaque_error(error), do: error
end

defimpl AshAi.ToToolError, for: AgentExamples.AI.Errors.LuaScriptFailed do
  def to_tool_error(error),
    do: AgentExamples.AI.Errors.LuaScriptFailed.tool_error_json(error)
end
