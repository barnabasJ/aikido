defmodule Aikido.AiReact.Actions.LlmTurn do
  @moduledoc "Adopts model responses, accumulates usage and continues with tools or queued messages."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion, Handoff}
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    response = input.arguments.turn

    if accepts_model_response?(state, input.arguments) do
      turn = ReqLLM.Response.classify(response)

      state
      |> accumulate_usage(response)
      |> record_response_content(turn)
      |> append_model_message(response)
      |> continue_from_classified_response(turn)
      |> Completion.apply_completion_requirements(input)
      |> Aikido.AiReact.Hooks.queue_event_hooks_if_changed(
        input,
        :after_model,
        model_hook_payload(input.arguments)
      )
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp accepts_model_response?(state, data) do
    is_nil(Map.get(state, :hook_terminal)) && state.status == :running &&
      is_nil(Map.get(state, :handoff_pending)) && state.request_id == data.request_id &&
      (is_nil(data[:iteration]) || data.iteration == state.iteration + 1)
  end

  defp accumulate_usage(state, response) do
    usage = ReqLLM.Response.usage(response) || %{}

    accumulated =
      Map.merge(Map.get(state, :usage, %{}), usage, fn _key, old, new ->
        if is_number(old) && is_number(new), do: old + new, else: new
      end)

    Map.merge(state, %{
      usage: accumulated,
      last_input_tokens: Handoff.input_tokens(ReqLLM.Response.usage(response))
    })
  end

  defp record_response_content(state, turn) do
    Map.merge(state, %{
      streaming_text: turn.text,
      streaming_thinking: turn.thinking,
      stream_attempt: 0
    })
  end

  defp append_model_message(state, response) do
    state
    |> Context.append_message(response.message)
    |> Map.update!(:iteration, &(&1 + 1))
  end

  defp continue_from_classified_response(state, %{type: :final_answer, text: text}) do
    if Map.get(state, :queued_messages, []) != [] && state.iteration < state.max_iterations do
      state
      |> resume_for_queued_messages()
      |> request_next_model_turn()
    else
      complete_run(state, text)
    end
  end

  defp continue_from_classified_response(state, %{
         type: :tool_calls,
         tool_calls: calls,
         text: text
       }) do
    calls = Enum.reject(calls, &ReqLLM.ToolCall.flagged_builtin?/1)

    cond do
      calls == [] ->
        continue_from_classified_response(state, %{type: :final_answer, text: text})

      state.iteration >= state.max_iterations ->
        complete_run(state, nil)

      true ->
        state
        |> record_pending_batch(calls)
        |> request_tool_executions()
    end
  end

  defp complete_run(state, answer) do
    Aikido.Types.ActionResult.new(state: %{state | status: :completed, result: answer})
  end

  defp resume_for_queued_messages(state) do
    Map.merge(state, %{
      status: :running,
      result: nil,
      streaming_text: "",
      streaming_thinking: ""
    })
  end

  defp request_next_model_turn(state) do
    {tools, _registry} = state.prepared_tools

    directive = %Aikido.AiReact.Directives.LLMCall{
      tools: tools,
      client: Map.get(state, :client, ReqLLM.Generation),
      model: state.model,
      context: state.context,
      request_id: state.request_id,
      llm_opts: state.llm_opts,
      options: Map.get(state, :options, %{}),
      iteration: state.iteration + 1
    }

    Aikido.Types.ActionResult.new(state: state, directives: [directive])
  end

  defp record_pending_batch(state, calls) do
    %{state | pending_tool_calls: calls, tool_results_received: []}
  end

  defp request_tool_executions(state) do
    {_tools, registry} = state.prepared_tools

    directives =
      Enum.map(state.pending_tool_calls, fn call ->
        %Aikido.AiReact.Directives.ToolExec{
          options: Map.get(state, :options, %{}),
          tool_call: call,
          registry: registry,
          tool_context: Map.get(state, :tool_context, %{}),
          request_id: state.request_id
        }
      end)

    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end

  defp model_hook_payload(data) do
    data
    |> Map.take([:query, :tool_call_id, :name, :content, :reason, :metadata])
    |> Map.put(:turn, Map.from_struct(data.turn))
  end
end
