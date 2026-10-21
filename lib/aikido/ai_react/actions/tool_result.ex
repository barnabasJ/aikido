defmodule Aikido.AiReact.Actions.ToolResult do
  @moduledoc "Adopts each pending tool result once and resumes the model after the complete batch."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion, DirectivePlan}
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    if is_nil(Map.get(input.arguments.state, :hook_terminal)) do
      input
      |> reduce()
      |> Completion.transition(
        input,
        :after_tool,
        Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
      )
      |> DirectivePlan.prepare_tools_and_handoff(input)
    else
      Aikido.Types.ActionResult.new(state: input.arguments.state)
    end
  end

  defp reduce(input) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    cond do
      slice.request_id != data.request_id ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      slice.status != :running || not is_nil(Map.get(slice, :handoff_pending)) ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      not Enum.any?(slice.pending_tool_calls, &(&1.id == data.tool_call_id)) ||
          Enum.any?(slice.tool_results_received, &(&1.tool_call_id == data.tool_call_id)) ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      true ->
        append_and_maybe_dispatch(data, slice)
    end
  end

  defp append_and_maybe_dispatch(data, slice) do
    msg = ReqLLM.Context.tool_result(data.tool_call_id, data.name, data.content)
    slice = Context.append_message(slice, msg)
    new_context = slice.context

    received =
      slice.tool_results_received ++
        [%{tool_call_id: data.tool_call_id, name: data.name, content: data.content}]

    if length(received) == length(slice.pending_tool_calls) do
      finalize_batch(slice)
    else
      Aikido.Types.ActionResult.new(
        state: %{slice | context: new_context, tool_results_received: received},
        directives: []
      )
    end
  end

  defp finalize_batch(slice) do
    current_signature = Aikido.AiReact.Slice.tool_call_signature(slice.pending_tool_calls)

    slice =
      maybe_append_cycle_warning(
        slice,
        slice.previous_tool_signature,
        current_signature
      )

    slice =
      Context.append_messages(
        slice,
        Enum.map(Map.get(slice, :queued_messages, []), &ReqLLM.Context.user/1)
      )

    warned_context = slice.context
    slice = Map.put(slice, :queued_messages, [])

    new_slice = %{
      slice
      | context: warned_context,
        pending_tool_calls: [],
        tool_results_received: [],
        previous_tool_signature: current_signature
    }

    directive = %Aikido.AiReact.Directives.LLMCall{
      options: Map.get(slice, :options, %{}),
      iteration: slice.iteration + 1,
      client: Map.get(slice, :client, ReqLLM.Generation),
      model: slice.model,
      context: warned_context,
      request_id: slice.request_id,
      llm_opts: slice.llm_opts
    }

    Aikido.Types.ActionResult.new(state: new_slice, directives: [directive])
  end

  defp maybe_append_cycle_warning(state, previous_signature, current_signature)
       when is_binary(previous_signature) and previous_signature == current_signature do
    Context.append_message(
      state,
      ReqLLM.Context.user(Aikido.AiReact.Slice.cycle_warning())
    )
  end

  defp maybe_append_cycle_warning(state, _previous, _current) do
    state
  end
end
