defmodule Aikido.Slices.AiReact.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, [action: :hook_completed], _context),
    do: Aikido.Hooks.completed(input.arguments.state, Map.delete(input.arguments, :state))

  def run(input, [action: :hook_context], _context),
    do: Aikido.Hooks.context(input.arguments.state, Map.delete(input.arguments, :state))

  def run(%{arguments: %{state: %{hook_terminal: terminal}}} = input, [action: action], _context)
      when not is_nil(terminal) and action in [:llm_turn, :tool_result, :failed] do
    Aikido.ActionResult.new(state: input.arguments.state)
  end

  def run(input, [action: action] = opts, context) do
    result = decide(input, opts, context)

    case result do
      {:ok, %{state: state}} when state != input.arguments.state ->
        event =
          case action do
            :ask -> :run_started
            :llm_turn -> :after_model
            :tool_result -> :after_tool
            :failed -> :run_failed
            :cancel -> :run_cancelled
          end

        payload = Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason])

        payload =
          if action == :llm_turn,
            do: Map.put(payload, :turn, Map.from_struct(input.arguments.turn)),
            else: payload

        Aikido.Hooks.transition(result, event, payload)

      _ ->
        result
    end
  end

  defp decide(input, [action: :ask], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    if ask_running?(slice) do
      {:error, :busy}
    else
      ask_open_run(data, slice)
    end
  end

  defp decide(input, [action: :cancel], _context) do
    signal = input.context.aikido.signal
    slice = input.arguments.state
    requested = Map.get(signal.data, :request_id)

    if slice.status == :running && (is_nil(requested) || requested == slice.request_id) do
      Aikido.ActionResult.new(
        state:
          slice
          |> Map.put(:status, :failed)
          |> Map.put(:error, :cancelled)
          |> Map.put(:hooks_pending, %{}),
        directives: []
      )
    else
      Aikido.ActionResult.new(state: slice, directives: [])
    end
  end

  defp decide(input, [action: :failed], _context) do
    reason = input.arguments[:reason]
    id = input.arguments[:request_id]
    slice = input.arguments.state

    cond do
      failed_stale?(slice, id) ->
        Aikido.ActionResult.new(state: slice, directives: [])

      slice.status != :running ->
        Aikido.ActionResult.new(state: slice, directives: [])

      true ->
        Aikido.ActionResult.new(
          state:
            slice
            |> Map.put(:status, :failed)
            |> Map.put(:error, reason)
            |> Map.put(:hooks_pending, %{}),
          directives: []
        )
    end
  end

  defp decide(input, [action: :llm_turn], _context) do
    turn = input.arguments[:turn]
    request_id = input.arguments[:request_id]
    slice = input.arguments.state

    cond do
      llm_turn_stale?(slice, request_id) -> Aikido.ActionResult.new(state: slice, directives: [])
      slice.status != :running -> Aikido.ActionResult.new(state: slice, directives: [])
      true -> llm_turn_handle_turn(turn, slice)
    end
  end

  defp decide(input, [action: :tool_result], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    cond do
      tool_result_stale?(slice, data.request_id) ->
        Aikido.ActionResult.new(state: slice, directives: [])

      slice.status != :running ->
        Aikido.ActionResult.new(state: slice, directives: [])

      not Enum.any?(slice.pending_tool_calls, &(&1.id == data.tool_call_id)) ||
          Enum.any?(slice.tool_results_received, &(&1.tool_call_id == data.tool_call_id)) ->
        Aikido.ActionResult.new(state: slice, directives: [])

      true ->
        tool_result_append_and_maybe_dispatch(data, slice)
    end
  end

  defp ask_open_run(data, slice) do
    model = data[:model] || ask_slice_field(slice, :model)

    tools =
      if is_nil(data[:tools]) do
        ask_slice_field(slice, :tools) || []
      else
        data[:tools]
      end

    system_prompt = data[:system_prompt] || ask_slice_field(slice, :system_prompt)
    max_iter = data[:max_iterations] || ask_slice_field(slice, :max_iterations) || 10
    llm_opts = Keyword.merge(ask_slice_field(slice, :llm_opts) || [], data[:llm_opts] || [])
    client = Map.get(data, :client) || ask_slice_field(slice, :client) || ReqLLM.Generation

    if is_nil(model) do
      {:error, :no_model}
    else
      ask_build_run(
        Map.put(data, :hooks, data[:hooks] || ask_slice_field(slice, :hooks) || []),
        system_prompt,
        model,
        tools,
        max_iter,
        llm_opts,
        client,
        ask_slice_field(slice, :tool_context) || %{}
      )
    end
  end

  defp ask_build_run(data, system_prompt, model, tools, max_iter, llm_opts, client, tool_context) do
    context = ask_build_initial_context(data.query, system_prompt)

    new_slice = %{
      status: :running,
      request_id: data.request_id,
      context: context,
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
      tool_context: tool_context,
      system_prompt: system_prompt,
      llm_opts: llm_opts
    }

    directive = %Aikido.Slices.AiReact.Directives.LLMCall{
      client: client,
      model: model,
      context: context,
      tools: tools,
      request_id: data.request_id,
      llm_opts: llm_opts
    }

    Aikido.ActionResult.new(state: new_slice, directives: [directive])
  end

  defp ask_running?(%{status: :running}) do
    true
  end

  defp ask_running?(_) do
    false
  end

  defp ask_slice_field(nil, _key) do
    nil
  end

  defp ask_slice_field(slice, key) when is_map(slice) do
    Map.get(slice, key)
  end

  defp ask_build_initial_context(query, nil) do
    ReqLLM.Context.new([ReqLLM.Context.user(query)])
  end

  defp ask_build_initial_context(query, system) when is_binary(system) do
    ReqLLM.Context.new([ReqLLM.Context.system(system), ReqLLM.Context.user(query)])
  end

  defp failed_stale?(%{request_id: current}, id) do
    current != id
  end

  defp llm_turn_stale?(%{request_id: current}, request_id) do
    current != request_id
  end

  defp llm_turn_handle_turn(%Aikido.Slices.AiReact.Turn{type: :final_answer, text: text}, slice) do
    new_context = ReqLLM.Context.append(slice.context, ReqLLM.Context.assistant(text || ""))

    new_slice = %{
      slice
      | iteration: slice.iteration + 1,
        context: new_context,
        status: :completed,
        result: text
    }

    Aikido.ActionResult.new(state: new_slice, directives: [])
  end

  defp llm_turn_handle_turn(
         %Aikido.Slices.AiReact.Turn{type: :tool_calls, tool_calls: tool_calls, text: text},
         slice
       ) do
    iteration = slice.iteration + 1

    msg_calls =
      Enum.map(tool_calls, fn tc -> %{id: tc.id, name: tc.name, arguments: tc.arguments} end)

    assistant_msg = ReqLLM.Context.assistant(text || "", tool_calls: msg_calls)
    new_context = ReqLLM.Context.append(slice.context, assistant_msg)

    if iteration >= slice.max_iterations do
      llm_turn_truncate(slice, new_context, iteration)
    else
      llm_turn_dispatch_tools(slice, new_context, iteration, msg_calls)
    end
  end

  defp llm_turn_truncate(slice, new_context, iteration) do
    new_slice = %{
      slice
      | iteration: iteration,
        context: new_context,
        status: :completed,
        result: nil
    }

    Aikido.ActionResult.new(state: new_slice, directives: [])
  end

  defp llm_turn_dispatch_tools(slice, new_context, iteration, msg_calls) do
    new_slice = %{
      slice
      | iteration: iteration,
        context: new_context,
        pending_tool_calls: msg_calls,
        tool_results_received: []
    }

    directives =
      Enum.map(msg_calls, fn call ->
        %Aikido.Slices.AiReact.Directives.ToolExec{
          tool_call: call,
          tool_modules: slice.tools,
          tool_context: Map.get(slice, :tool_context, %{}),
          request_id: slice.request_id
        }
      end)

    Aikido.ActionResult.new(state: new_slice, directives: directives)
  end

  defp tool_result_stale?(%{request_id: current}, request_id) do
    current != request_id
  end

  defp tool_result_append_and_maybe_dispatch(data, slice) do
    msg = ReqLLM.Context.tool_result(data.tool_call_id, data.name, data.content)
    new_context = ReqLLM.Context.append(slice.context, msg)

    received =
      slice.tool_results_received ++
        [%{tool_call_id: data.tool_call_id, name: data.name, content: data.content}]

    if length(received) == length(slice.pending_tool_calls) do
      tool_result_finalize_batch(slice, new_context)
    else
      Aikido.ActionResult.new(
        state: %{slice | context: new_context, tool_results_received: received},
        directives: []
      )
    end
  end

  defp tool_result_finalize_batch(slice, new_context) do
    current_signature = Aikido.Slices.AiReact.tool_call_signature(slice.pending_tool_calls)

    {warned_context, _} =
      tool_result_maybe_append_cycle_warning(
        new_context,
        slice.previous_tool_signature,
        current_signature
      )

    new_slice = %{
      slice
      | context: warned_context,
        pending_tool_calls: [],
        tool_results_received: [],
        previous_tool_signature: current_signature
    }

    directive = %Aikido.Slices.AiReact.Directives.LLMCall{
      client: Map.get(slice, :client, ReqLLM.Generation),
      model: slice.model,
      context: warned_context,
      tools: slice.tools,
      request_id: slice.request_id,
      llm_opts: slice.llm_opts
    }

    Aikido.ActionResult.new(state: new_slice, directives: [directive])
  end

  defp tool_result_maybe_append_cycle_warning(context, previous_signature, current_signature)
       when is_binary(previous_signature) and previous_signature == current_signature do
    {ReqLLM.Context.append(context, ReqLLM.Context.user(Aikido.Slices.AiReact.cycle_warning())),
     :warned}
  end

  defp tool_result_maybe_append_cycle_warning(context, _previous, _current) do
    {context, :no_warning}
  end
end
