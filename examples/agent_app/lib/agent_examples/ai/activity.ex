defmodule AgentExamples.AI.Activity do
  @moduledoc "Projects conversation state into a small, credential-free description of an agent's current work."

  def from_state(state) do
    messages = messages(state)
    calls = latest_tool_calls(messages)
    results = for %{role: :tool, tool_call_id: id} <- messages, into: MapSet.new(), do: id
    pending = Map.get(state, :pending_tool_calls, [])

    %{
      status: Map.get(state, :status, :idle),
      stage: stage(state, pending),
      iteration: Map.get(state, :iteration, 0),
      task: latest_user_text(messages),
      tools:
        Enum.map(calls, &%{name: &1.function.name, finished?: MapSet.member?(results, &1.id)}),
      output: Map.get(state, :result) || Map.get(state, :streaming_text, ""),
      error: Map.get(state, :error)
    }
  end

  defp messages(%{context: %ReqLLM.Context{messages: messages}}), do: messages
  defp messages(_), do: []

  defp latest_tool_calls(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %{role: :assistant, tool_calls: calls} when is_list(calls) and calls != [] -> calls
      _ -> nil
    end)
  end

  defp latest_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :user, content: parts} ->
        text = Enum.map_join(parts, "", fn part -> Map.get(part, :text) || "" end)
        if String.starts_with?(text, "[Hook context:"), do: nil, else: text

      _ ->
        nil
    end)
  end

  defp stage(%{status: :setup}, _), do: "Preparing tools"
  defp stage(%{status: :waiting}, _), do: "Waiting for tracked work"
  defp stage(%{status: :completed}, _), do: "Completed"
  defp stage(%{status: :failed}, _), do: "Failed"
  defp stage(%{status: :running}, [_ | _]), do: "Tool calls pending"
  defp stage(%{status: :running}, []), do: "Waiting for model response"
  defp stage(_, _), do: "Ready for a task"
end
