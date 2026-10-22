defmodule AgentExamples.AI.Activity do
  @moduledoc "Projects conversation state into a small, credential-free description of an agent's current work."

  def from_state(state) do
    messages = state |> messages() |> current_task_messages()
    calls = Enum.flat_map(messages, &(&1.tool_calls || []))

    results =
      for %{role: :tool, tool_call_id: id} = message <- messages,
          into: %{},
          do: {id, message}

    pending = Map.get(state, :pending_tool_calls, [])

    %{
      status: Map.get(state, :status, :idle),
      stage: stage(state, pending),
      iteration: Map.get(state, :iteration, 0),
      task: latest_user_text(messages),
      tools: Enum.map(calls, &describe_tool_call(&1, results, Map.get(state, :status))),
      output: Map.get(state, :result) || Map.get(state, :streaming_text, ""),
      error: Map.get(state, :error)
    }
  end

  defp messages(%{context: %ReqLLM.Context{messages: messages}}), do: messages
  defp messages(_), do: []

  defp current_task_messages(messages) do
    start =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(0, fn {message, index} ->
        if message.role == :user && !String.starts_with?(message_text(message), "[Hook context:"),
          do: index
      end)

    Enum.drop(messages, start)
  end

  defp describe_tool_call(call, results, status) do
    result = Map.get(results, call.id)
    arguments = decode_arguments(call.function.arguments)
    input = Map.get(arguments, "input", arguments)

    %{
      id: call.id,
      name: call.function.name,
      label: tool_label(call.function.name),
      status: tool_status(result, status),
      input: Map.get(input, "script") || Jason.encode!(arguments, pretty: true),
      result: if(result, do: message_text(result))
    }
  end

  defp decode_arguments(arguments) when is_map(arguments), do: arguments

  defp decode_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp tool_status(nil, status) when status in [:completed, :failed], do: :unfinished
  defp tool_status(nil, _), do: :pending

  defp tool_status(message, _) do
    if message.metadata[:aikido_tool_error?] do
      :failed
    else
      case Jason.decode(message_text(message)) do
        {:ok, %{"error" => error}} when not is_nil(error) -> :failed
        _ -> :completed
      end
    end
  end

  defp tool_label("run_lua"), do: "Run Lua script"
  defp tool_label("delegate"), do: "Delegate work"
  defp tool_label("spawn_worker"), do: "Spawn worker"
  defp tool_label("team_roster"), do: "List teammates"
  defp tool_label(name), do: name |> String.replace("_", " ") |> String.capitalize()

  defp message_text(message),
    do: Enum.map_join(message.content, "", fn part -> Map.get(part, :text) || "" end)

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
