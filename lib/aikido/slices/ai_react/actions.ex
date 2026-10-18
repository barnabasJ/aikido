defmodule Aikido.Slices.AiReact.Actions do
  @moduledoc "Native Ash state-transition actions for the ai_react slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :ask, Aikido.ActionResult do
      argument :state, :term
      argument :query, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      argument :model, :term
      argument :client, :atom
      argument :tools, {:array, :term}
      argument :system_prompt, :string
      argument :max_iterations, :integer, constraints: [min: 1]
      argument :llm_opts, Aikido.Types.Native, constraints: [kind: :keyword_list]
      description "Open a ReAct run on a Aikido.Slices.AiReact-equipped agent."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case ask_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :cancel, Aikido.ActionResult do
      argument :state, :term
      argument :request_id, :string, default: nil

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case cancel_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :failed, Aikido.ActionResult do
      argument :state, :term
      argument :reason, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Settle the slice as :failed with the reason."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case failed_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :llm_turn, Aikido.ActionResult do
      argument :state, :term
      argument :turn, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process a completed LLM turn and decide the next ReAct step."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case llm_turn_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :tool_result, Aikido.ActionResult do
      argument :state, :term
      argument :tool_call_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :content, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process one tool result and fan-in to the next LLM turn."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case tool_result_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp ask_reduce(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    if ask_running?(slice) do
      {:error, :busy}
    else
      ask_open_run(data, slice)
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
        data,
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

    {:ok, new_slice, [directive]}
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

  defp cancel_reduce(signal, slice, _opts, _context) do
    requested = Map.get(signal.data, :request_id)

    if slice.status == :running && (is_nil(requested) || requested == slice.request_id) do
      {:ok, %{slice | status: :failed, error: :cancelled}, []}
    else
      {:ok, slice, []}
    end
  end

  defp failed_reduce(%Jido.Signal{data: %{reason: reason, request_id: id}}, slice, _opts, _ctx) do
    cond do
      failed_stale?(slice, id) -> {:ok, slice, []}
      slice.status != :running -> {:ok, slice, []}
      true -> {:ok, %{slice | status: :failed, error: reason}, []}
    end
  end

  defp failed_stale?(%{request_id: current}, id) do
    current != id
  end

  defp llm_turn_reduce(
         %Jido.Signal{data: %{turn: turn, request_id: request_id}},
         slice,
         _opts,
         _ctx
       ) do
    cond do
      llm_turn_stale?(slice, request_id) -> {:ok, slice, []}
      slice.status != :running -> {:ok, slice, []}
      true -> llm_turn_handle_turn(turn, slice)
    end
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

    {:ok, new_slice, []}
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

    {:ok, new_slice, []}
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

    {:ok, new_slice, directives}
  end

  defp tool_result_reduce(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    cond do
      tool_result_stale?(slice, data.request_id) -> {:ok, slice, []}
      slice.status != :running -> {:ok, slice, []}
      true -> tool_result_append_and_maybe_dispatch(data, slice)
    end
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
      {:ok, %{slice | context: new_context, tool_results_received: received}, []}
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

    {:ok, new_slice, [directive]}
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
