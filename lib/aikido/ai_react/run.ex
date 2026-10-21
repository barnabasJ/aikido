defmodule Aikido.AiReact.Run do
  @moduledoc "Pure run setup shared by ask, message and delivery actions."
  alias Aikido.AiReact.Context

  @doc false
  def open(data, slice) do
    slice = slice || %{}
    model = data[:model] || Map.get(slice, :model)
    tools = data[:tools] || Map.get(slice, :tools) || []

    system_prompt = data[:system_prompt] || Map.get(slice, :system_prompt)
    max_iter = data[:max_iterations] || Map.get(slice, :max_iterations) || 10
    llm_opts = Keyword.merge(Map.get(slice, :llm_opts) || [], data[:llm_opts] || [])
    client = Map.get(data, :client) || Map.get(slice, :client) || ReqLLM.Generation

    if is_nil(model) do
      {:error, :no_model}
    else
      build(
        Map.put(data, :hooks, data[:hooks] || Map.get(slice, :hooks) || []),
        slice,
        system_prompt,
        model,
        tools,
        max_iter,
        llm_opts,
        client,
        Map.merge(Map.get(slice, :tool_context) || %{}, data[:tool_context] || %{})
      )
    end
  end

  defp build(
         data,
         slice,
         system_prompt,
         model,
         tools,
         max_iter,
         llm_opts,
         client,
         tool_context
       ) do
    context =
      case Map.get(slice, :context) do
        %ReqLLM.Context{} = context ->
          context = Context.close_tool_calls(context)
          messages = Enum.reject(context.messages, &(&1.role == :system))
          system = if system_prompt, do: [ReqLLM.Context.system(system_prompt)], else: []
          %{context | messages: system ++ messages}

        _ ->
          ReqLLM.Context.new(
            if(system_prompt, do: [ReqLLM.Context.system(system_prompt)], else: [])
          )
      end

    base = slice
    cached = Map.get(base, :estimated_tokens)

    base =
      if Map.get(base, :context) == context && is_integer(cached) && cached > 0,
        do: base,
        else: Context.replace_context(base, context)

    base =
      Context.append_messages(
        base,
        Enum.map(Map.get(base, :queued_messages, []) ++ [data.query], &ReqLLM.Context.user/1)
      )

    context = base.context

    options = data[:options] || Map.get(slice, :options) || %Aikido.AiReact.Options{}

    new_slice = %{
      status: :setup,
      prepared_tools: nil,
      handoff_pending: nil,
      handoff_count: 0,
      last_handoff: nil,
      last_input_tokens: nil,
      tool_preparation: [],
      options: options,
      run_metadata: data[:metadata] || %{},
      queued_messages: [],
      streaming_text: "",
      streaming_thinking: "",
      stream_attempt: 0,
      usage: %{},
      request_id: data.request_id,
      context: context,
      estimated_tokens: base.estimated_tokens,
      iteration: 0,
      max_iterations: max_iter,
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: nil,
      model: model,
      hooks: data[:hooks] || [],
      hooks_pending: %{},
      hook_sequence: 0,
      hook_context: [],
      hook_errors: [],
      hook_terminal: nil,
      client: client,
      tools: tools,
      tool_options: data[:tool_options] || Map.get(slice, :tool_options, otp_app: :aikido),
      tool_context: tool_context,
      system_prompt: system_prompt,
      llm_opts: llm_opts
    }

    directive = %Aikido.AiReact.Directives.LLMCall{
      options: options,
      iteration: 1,
      client: client,
      model: model,
      context: context,
      request_id: data.request_id,
      llm_opts: llm_opts
    }

    Aikido.Types.ActionResult.new(
      state: Map.merge(slice, new_slice),
      directives: [directive]
    )
  end
end
