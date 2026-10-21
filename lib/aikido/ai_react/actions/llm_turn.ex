defmodule Aikido.AiReact.Actions.LlmTurn do
  @moduledoc "Adopts model responses, accumulates usage and continues with tools or queued messages."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion, Handoff}
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    if is_nil(Map.get(input.arguments.state, :hook_terminal)) do
      input
      |> adopt_model_response()
      |> Completion.transition(
        input,
        :after_model,
        Map.put(
          Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata]),
          :turn,
          Map.from_struct(input.arguments.turn)
        )
      )
    else
      Aikido.Types.ActionResult.new(state: input.arguments.state)
    end
  end

  defp adopt_model_response(input) do
    response = input.arguments[:turn]
    turn = ReqLLM.Response.classify(response)
    request_id = input.arguments[:request_id]
    slice = input.arguments.state

    cond do
      not is_nil(Map.get(slice, :handoff_pending)) || slice.request_id != request_id ||
          (input.arguments[:iteration] && input.arguments.iteration != slice.iteration + 1) ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      slice.status != :running ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      true ->
        usage =
          Map.merge(Map.get(slice, :usage, %{}), ReqLLM.Response.usage(response) || %{}, fn _key,
                                                                                            old,
                                                                                            new ->
            if is_number(old) && is_number(new), do: old + new, else: new
          end)

        continue_from_classified_response(
          response,
          turn,
          Map.merge(slice, %{
            usage: usage,
            last_input_tokens: Handoff.input_tokens(ReqLLM.Response.usage(response)),
            streaming_text: turn.text,
            streaming_thinking: turn.thinking,
            stream_attempt: 0
          })
        )
    end
  end

  defp continue_from_classified_response(response, %{type: :final_answer, text: text}, slice) do
    slice = Context.append_message(slice, response.message)
    new_context = slice.context

    new_slice = %{
      slice
      | iteration: slice.iteration + 1,
        context: new_context,
        status: :completed,
        result: text
    }

    queued = Map.get(slice, :queued_messages, [])

    if queued != [] && new_slice.iteration < slice.max_iterations do
      new_slice =
        Map.merge(new_slice, %{
          status: :running,
          result: nil,
          context: new_context,
          streaming_text: "",
          streaming_thinking: ""
        })

      {tools, _registry} = slice.prepared_tools

      effect = %Aikido.AiReact.Directives.LLMCall{
        tools: tools,
        client: Map.get(slice, :client, ReqLLM.Generation),
        model: slice.model,
        context: new_context,
        request_id: slice.request_id,
        llm_opts: slice.llm_opts,
        options: Map.get(slice, :options, %{}),
        iteration: new_slice.iteration + 1
      }

      Aikido.Types.ActionResult.new(state: new_slice, directives: [effect])
    else
      Aikido.Types.ActionResult.new(state: new_slice, directives: [])
    end
  end

  defp continue_from_classified_response(
         response,
         %{type: :tool_calls, tool_calls: tool_calls, text: text},
         slice
       ) do
    iteration = slice.iteration + 1

    msg_calls = Enum.reject(tool_calls, &ReqLLM.ToolCall.flagged_builtin?/1)

    if msg_calls == [] do
      continue_from_classified_response(response, %{type: :final_answer, text: text}, slice)
    else
      slice = Context.append_message(slice, response.message)
      new_context = slice.context

      if iteration >= slice.max_iterations do
        complete_at_iteration_limit(slice, new_context, iteration)
      else
        record_batch_and_request_tools(slice, new_context, iteration, msg_calls)
      end
    end
  end

  defp complete_at_iteration_limit(slice, new_context, iteration) do
    new_slice = %{
      slice
      | iteration: iteration,
        context: new_context,
        status: :completed,
        result: nil
    }

    Aikido.Types.ActionResult.new(state: new_slice, directives: [])
  end

  defp record_batch_and_request_tools(slice, new_context, iteration, msg_calls) do
    {_tools, registry} = slice.prepared_tools

    new_slice = %{
      slice
      | iteration: iteration,
        context: new_context,
        pending_tool_calls: msg_calls,
        tool_results_received: []
    }

    directives =
      Enum.map(msg_calls, fn call ->
        %Aikido.AiReact.Directives.ToolExec{
          options: Map.get(slice, :options, %{}),
          tool_call: call,
          registry: registry,
          tool_context: Map.get(slice, :tool_context, %{}),
          request_id: slice.request_id
        }
      end)

    Aikido.Types.ActionResult.new(state: new_slice, directives: directives)
  end
end
