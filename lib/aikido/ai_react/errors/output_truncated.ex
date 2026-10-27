defmodule Aikido.AiReact.Errors.OutputTruncated do
  @moduledoc "The provider exhausted its output budget before completing an answer or tool call."
  use Splode.Error, fields: [:max_tokens], class: :invalid

  def message(error) do
    budget = if error.max_tokens, do: " (max_tokens: #{error.max_tokens})", else: ""

    "The provider reached its output-token limit#{budget}. The answer or tool arguments " <>
      "are incomplete and were not accepted as a completed result. Increase max_tokens " <>
      "(reasoning may share this budget), request a shorter answer, or reduce reasoning " <>
      "if the provider supports it before retrying."
  end
end

defimpl AshAi.ToToolError, for: Aikido.AiReact.Errors.OutputTruncated do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.AiReact.Errors.OutputTruncated do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Model output truncated",
      code: "model_output_truncated",
      fields: [],
      vars: %{max_tokens: error.max_tokens}
    }
  end
end
