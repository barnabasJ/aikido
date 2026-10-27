defmodule Aikido.AiReact.Actions.ToolResult do
  @moduledoc "Adopts each pending tool result once and resumes the model after the complete batch."
  use Ash.Resource.Actions.Implementation

  @cycle_warning "The completed tool batch matches a previous batch under this run’s loop comparison. Do NOT repeat this pattern. Use the available results to form a final answer, or try a different approach."
  alias Aikido.AiReact.RunState
  alias Aikido.AiReact.Conversation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    data = Map.delete(input.arguments, :state)

    if accepts_tool_result?(state, data) do
      state
      |> append_tool_message(data)
      |> record_received_result(data)
      |> resume_when_batch_complete()
      |> RunState.resolve_run_outcome(input)
      |> Aikido.AiReact.HookQueue.queue_event_hooks_if_changed(
        input,
        :after_tool,
        Map.take(data, [:query, :tool_call_id, :name, :content, :reason, :metadata])
      )
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp accepts_tool_result?(state, data) do
    is_nil(Map.get(state, :hook_terminal)) &&
      state.request_id == data.request_id && state.status == :running &&
      is_nil(Map.get(state, :handoff_pending)) &&
      Enum.any?(state.pending_tool_calls, &(&1.id == data.tool_call_id)) &&
      not Enum.any?(state.tool_results_received, &(&1.tool_call_id == data.tool_call_id))
  end

  defp append_tool_message(state, data) do
    message = ReqLLM.Context.tool_result(data.tool_call_id, data.name, data.content)

    metadata =
      Map.put(message.metadata, :aikido_tool_error?, Map.get(data, :error?, false))

    Conversation.append_message(state, %{message | metadata: metadata})
  end

  defp record_received_result(state, data) do
    result = %{
      tool_call_id: data.tool_call_id,
      name: data.name,
      content: data.content,
      error?: Map.get(data, :error?, false)
    }

    %{state | tool_results_received: state.tool_results_received ++ [result]}
  end

  defp resume_when_batch_complete(state) do
    if length(state.tool_results_received) == length(state.pending_tool_calls) do
      state = state |> record_batch_signature() |> clear_completed_batch()

      if state.status == :failed,
        do: Aikido.Types.ActionResult.new(state: state),
        else: Aikido.AiReact.RunState.request_model_turn(state)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp record_batch_signature(state) do
    if Enum.any?(state.tool_results_received, &Map.get(&1, :error?, false)) do
      Aikido.AiReact.ToolLoopGuard.record_batch(state, nil)
    else
      with {:ok, signature} <- tool_batch_signature(state) do
        state
        |> maybe_append_cycle_warning(state.previous_tool_signature, signature)
        |> Map.put(:previous_tool_signature, signature)
        |> Aikido.AiReact.ToolLoopGuard.record_batch(signature)
      else
        {:error, reason} -> %{state | status: :failed, error: {:tool_loop_key_failed, reason}}
      end
    end
  end

  defp clear_completed_batch(state) do
    %{state | pending_tool_calls: [], tool_results_received: []}
  end

  defp maybe_append_cycle_warning(state, previous_signature, current_signature)
       when is_binary(previous_signature) and previous_signature == current_signature do
    Conversation.append_message(state, ReqLLM.Context.user(@cycle_warning))
  end

  defp maybe_append_cycle_warning(state, _previous, _current), do: state

  defp tool_batch_signature(state) do
    batch = completed_tool_batch(state.pending_tool_calls, state.tool_results_received)

    with {:ok, key} <- comparison_key(batch, Map.get(state.options, :tool_loop_key)) do
      signature =
        key
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, signature}
    end
  end

  defp completed_tool_batch(tool_calls, results) do
    by_id = Map.new(results, &{&1.tool_call_id, &1.content})

    tool_calls
    |> Enum.map(fn call ->
      name = Map.get(call, :name) || Map.get(call, "name") || ""
      arguments = Map.get(call, :arguments) || Map.get(call, "arguments") || ""
      {name, arguments, Map.fetch!(by_id, Map.get(call, :id) || Map.get(call, "id"))}
    end)
    |> Enum.sort()
  end

  defp comparison_key(batch, nil), do: {:ok, batch}

  defp comparison_key(batch, {module, function, arguments}) do
    case apply(module, function, [batch | arguments]) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, {module, function, reason}}
      _other -> {:error, {module, function, :invalid_return}}
    end
  rescue
    exception -> {:error, {module, function, exception}}
  catch
    kind, reason -> {:error, {module, function, {kind, reason}}}
  end
end
