defmodule Aikido.AiReact.Actions.ToolResult do
  @moduledoc "Adopts each pending tool result once and resumes the model after the complete batch."
  use Ash.Resource.Actions.Implementation

  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."
  alias Aikido.AiReact.{Completion}
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    if is_nil(Map.get(input.arguments.state, :hook_terminal)) do
      input
      |> record_tool_result()
      |> Completion.transition(
        input,
        :after_tool,
        Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
      )
    else
      Aikido.Types.ActionResult.new(state: input.arguments.state)
    end
  end

  defp record_tool_result(input) do
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
        append_result_and_resume_when_complete(data, slice)
    end
  end

  defp append_result_and_resume_when_complete(data, slice) do
    msg = ReqLLM.Context.tool_result(data.tool_call_id, data.name, data.content)
    slice = Context.append_message(slice, msg)
    new_context = slice.context

    received =
      slice.tool_results_received ++
        [%{tool_call_id: data.tool_call_id, name: data.name, content: data.content}]

    if length(received) == length(slice.pending_tool_calls) do
      complete_batch_and_request_model(slice)
    else
      Aikido.Types.ActionResult.new(
        state: %{slice | context: new_context, tool_results_received: received},
        directives: []
      )
    end
  end

  defp complete_batch_and_request_model(slice) do
    current_signature = tool_call_signature(slice.pending_tool_calls)

    slice =
      maybe_append_cycle_warning(
        slice,
        slice.previous_tool_signature,
        current_signature
      )

    new_slice = %{
      slice
      | pending_tool_calls: [],
        tool_results_received: [],
        previous_tool_signature: current_signature
    }

    {tools, _registry} = slice.prepared_tools

    directive = %Aikido.AiReact.Directives.LLMCall{
      options: Map.get(slice, :options, %{}),
      iteration: slice.iteration + 1,
      tools: tools,
      client: Map.get(slice, :client, ReqLLM.Generation),
      model: slice.model,
      context: slice.context,
      request_id: slice.request_id,
      llm_opts: slice.llm_opts
    }

    Aikido.Types.ActionResult.new(state: new_slice, directives: [directive])
  end

  defp maybe_append_cycle_warning(state, previous_signature, current_signature)
       when is_binary(previous_signature) and previous_signature == current_signature do
    Context.append_message(
      state,
      ReqLLM.Context.user(@cycle_warning)
    )
  end

  defp maybe_append_cycle_warning(state, _previous, _current) do
    state
  end

  defp tool_call_signature(tool_calls) do
    tool_calls
    |> Enum.map(fn call ->
      name = Map.get(call, :name) || Map.get(call, "name") || ""
      arguments = Map.get(call, :arguments) || Map.get(call, "arguments") || ""
      "#{name}:#{inspect(arguments)}"
    end)
    |> Enum.sort()
    |> Enum.join("|")
  end
end
