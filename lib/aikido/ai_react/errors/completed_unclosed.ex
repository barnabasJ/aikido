defmodule Aikido.AiReact.Errors.CompletedUnclosed do
  @moduledoc "An idle model answered again after a reminder without closing its blocking work."
  use Splode.Error, fields: [:todos], class: :invalid

  def message(error) do
    obligations = Enum.map_join(error.todos || [], "; ", &"#{&1.id}: #{&1.text}")

    "The model answered again without resolving its blocking obligations after a reminder: " <>
      obligations <>
      ". No completion was accepted. Inspect the outstanding work before restarting."
  end
end

defimpl AshAi.ToToolError, for: Aikido.AiReact.Errors.CompletedUnclosed do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.AiReact.Errors.CompletedUnclosed do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Blocking work left unclosed",
      code: "completed_unclosed",
      fields: [],
      vars: %{todos: error.todos}
    }
  end
end
