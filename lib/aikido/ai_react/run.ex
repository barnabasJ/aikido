defmodule Aikido.AiReact.Run do
  @moduledoc "Builds initial run state and releases tool/handoff state at terminal transitions."
  alias Aikido.AiReact.Context

  @doc false
  def open(data, state) do
    state = state || %{}

    with {:ok, configuration} <- resolve_configuration(data, state) do
      state
      |> refresh_conversation(configuration.system_prompt)
      |> append_opening_messages(data.query)
      |> reset_run(data, configuration)
      |> request_tool_setup()
    end
  end

  @doc "Discard the prepared callbacks and pending handoff when a run settles."
  def clear_tools_and_handoff(state) do
    Map.merge(state, %{prepared_tools: nil, handoff_pending: nil})
  end

  defp resolve_configuration(data, state) do
    model = data[:model] || Map.get(state, :model)

    if is_nil(model) do
      {:error, :no_model}
    else
      {:ok,
       %{
         model: model,
         tools: data[:tools] || Map.get(state, :tools) || [],
         system_prompt: data[:system_prompt] || Map.get(state, :system_prompt),
         max_iterations: data[:max_iterations] || Map.get(state, :max_iterations) || 10,
         llm_opts: Keyword.merge(Map.get(state, :llm_opts) || [], data[:llm_opts] || []),
         client: data[:client] || Map.get(state, :client) || ReqLLM.Generation,
         hooks: data[:hooks] || Map.get(state, :hooks) || [],
         options: data[:options] || Map.get(state, :options) || %Aikido.AiReact.Options{},
         tool_options: data[:tool_options] || Map.get(state, :tool_options, otp_app: :aikido),
         tool_context: Map.merge(Map.get(state, :tool_context) || %{}, data[:tool_context] || %{})
       }}
    end
  end

  defp refresh_conversation(state, system_prompt) do
    context =
      state
      |> Map.get(:context)
      |> close_interrupted_tool_calls()
      |> replace_system_prompt(system_prompt)

    cached = Map.get(state, :estimated_tokens)

    if Map.get(state, :context) == context && is_integer(cached) && cached > 0,
      do: state,
      else: Context.replace_context(state, context)
  end

  defp close_interrupted_tool_calls(%ReqLLM.Context{} = context),
    do: Context.close_tool_calls(context)

  defp close_interrupted_tool_calls(_), do: ReqLLM.Context.new()

  defp replace_system_prompt(context, system_prompt) do
    messages = Enum.reject(context.messages, &(&1.role == :system))
    system = if system_prompt, do: [ReqLLM.Context.system(system_prompt)], else: []
    %{context | messages: system ++ messages}
  end

  defp append_opening_messages(state, query) do
    messages =
      state
      |> Map.get(:queued_messages, [])
      |> Enum.concat([query])
      |> Enum.map(&ReqLLM.Context.user/1)

    Context.append_messages(state, messages)
  end

  defp reset_run(state, data, configuration) do
    state
    |> Map.merge(configuration)
    |> Map.merge(%{
      status: :setup,
      request_id: data.request_id,
      run_metadata: data[:metadata] || %{},
      prepared_tools: nil,
      handoff_pending: nil,
      handoff_count: 0,
      last_handoff: nil,
      last_input_tokens: nil,
      queued_messages: [],
      streaming_text: "",
      streaming_thinking: "",
      stream_attempt: 0,
      usage: %{},
      iteration: 0,
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: nil,
      hooks_pending: %{},
      hook_sequence: 0,
      hook_context: [],
      hook_errors: [],
      hook_terminal: nil
    })
  end

  defp request_tool_setup(state) do
    directive = %Aikido.AiReact.Directives.PrepareTools{
      options: state.options,
      tools: state.tools,
      tool_options: state.tool_options,
      request_id: state.request_id
    }

    Aikido.Types.ActionResult.new(state: state, directives: [directive])
  end
end
