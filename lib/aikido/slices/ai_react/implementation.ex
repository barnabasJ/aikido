defmodule Aikido.Slices.AiReact.Implementation do
  @moduledoc """
  Pure reducers for the ReAct conversation and run lifecycle.

  The native action name selects the command or result handler. Native
  arguments supply `state`, request correlation and payload; returned state tracks
  conversation, tools and hooks. Preparation, model, tool and hook work is returned
  as directives, with context handoff and todo completion planned between steps.
  """
  use Ash.Resource.Actions.Implementation

  alias Aikido.AI.Context, as: Conversation
  alias Aikido.Slices.AiReact.Directives.{LLMCall, PrepareTools, ToolExec}

  @impl true
  def run(input, _opts, context) do
    case handle(input, input.action.name, context) do
      {:ok, %{state: state, directives: []}} = unchanged when state == input.arguments.state ->
        unchanged

      result ->
        result = prepare_tools(result)
        Aikido.AI.Handoff.plan(result)
    end
  end

  defp prepare_tools({:ok, result}) do
    state = result.state

    cond do
      state.status not in [:setup, :running, :waiting] ->
        {:ok,
         %{
           result
           | state:
               Map.merge(state, %{
                 handoff_pending: nil,
                 prepared_tools: nil,
                 tool_preparation: []
               })
         }}

      prepared = Map.get(state, :prepared_tools) ->
        directives =
          Enum.map(result.directives, fn
            %LLMCall{mode: :handoff} = effect -> %{effect | tools: []}
            %LLMCall{} = effect -> %{effect | tools: elem(prepared, 0)}
            %ToolExec{} = effect -> %{effect | registry: elem(prepared, 1)}
            effect -> effect
          end)

        {:ok, %{result | directives: directives}}

      true ->
        {waiting, other} =
          Enum.split_with(
            result.directives,
            &match?(%{__struct__: module} when module in [LLMCall, ToolExec], &1)
          )

        pending = Map.get(state, :tool_preparation, []) ++ waiting
        state = Map.put(state, :tool_preparation, pending)

        if pending != [] && Map.get(result.state, :tool_preparation, []) == [] do
          effect = %PrepareTools{
            options: Map.get(state, :options, %{}),
            tools: state.tools,
            tool_options: state.tool_options,
            request_id: state.request_id
          }

          {:ok,
           %{
             result
             | state: state,
               directives: other ++ [effect]
           }}
        else
          {:ok, %{result | state: state, directives: other}}
        end
    end
  end

  defp prepare_tools(error), do: error

  defp handle(input, :handoff_completed, _context),
    do: Aikido.AI.Handoff.complete(input.arguments.state, Map.delete(input.arguments, :state))

  defp handle(input, :handoff_failed, _context),
    do: Aikido.AI.Handoff.fail(input.arguments.state, Map.delete(input.arguments, :state))

  defp handle(input, :tools_ready, _context) do
    state = input.arguments.state

    if state.request_id == input.arguments.request_id && state.status == :setup &&
         Map.get(state, :tool_preparation, []) != [] do
      state =
        Conversation.append_messages(
          state,
          Enum.map(state.queued_messages, &ReqLLM.Context.user/1)
        )

      state = Map.put(state, :queued_messages, [])

      {directives, state} =
        Enum.map_reduce(state.tool_preparation, state, fn
          %LLMCall{} = effect, state ->
            {state, effect} = Aikido.Hooks.prepare_model(state, effect)
            {effect, state}

          effect, state ->
            {effect, state}
        end)

      state =
        state
        |> Map.put(:status, :running)
        |> Map.put(:prepared_tools, input.arguments.prepared_tools)
        |> Map.put(:tool_preparation, [])

      Aikido.Types.ActionResult.new(state: state, directives: directives)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp handle(input, :hook_completed, _context),
    do: Aikido.Hooks.completed(input.arguments.state, Map.delete(input.arguments, :state))

  defp handle(input, :hook_context, _context),
    do: Aikido.Hooks.context(input.arguments.state, Map.delete(input.arguments, :state))

  defp handle(input, action, context) when action in [:message, :deliver] do
    state = input.arguments.state
    scope = caller_scope(input)

    if state.status in [:setup, :running, :waiting] &&
         Map.merge(%{actor: nil, tenant: nil}, Map.get(state, :run_scope, %{})) != scope do
      {:error, :scope_mismatch}
    else
      run_message(input, action, context)
    end
  end

  defp handle(input, :handoff, _context) do
    state = input.arguments.state

    if state.status in [:setup, :running, :waiting] do
      {:error, :busy}
    else
      with {:ok, context} <- ReqLLM.Context.normalize(input.arguments.messages) do
        Aikido.Types.ActionResult.new(state: Conversation.replace_context(state, context))
      end
    end
  end

  defp handle(input, :todo_changed, _context) do
    state = input.arguments.state

    if state.status == :waiting do
      state = apply_todo_gate(state, input.context.aikido.agent.state)

      Aikido.Hooks.transition(Aikido.Types.ActionResult.new(state: state), :after_model, %{
        todo_completion: true
      })
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp handle(input, :stream, _context) do
    data = input.arguments
    state = data.state

    if state.status == :running && is_nil(Map.get(state, :handoff_pending)) &&
         state.request_id == data.request_id &&
         state.iteration + 1 == data.iteration &&
         data.attempt >= Map.get(state, :stream_attempt, 0) do
      reset? = data.attempt > Map.get(state, :stream_attempt, 0)

      state =
        Map.merge(state, %{
          stream_attempt: data.attempt,
          streaming_text:
            if(reset?, do: "", else: Map.get(state, :streaming_text, "")) <> data.text,
          streaming_thinking:
            if(reset?, do: "", else: Map.get(state, :streaming_thinking, "")) <> data.thinking
        })

      Aikido.Types.ActionResult.new(state: state)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp handle(
         %{arguments: %{state: %{hook_terminal: terminal}}} = input,
         action,
         _context
       )
       when not is_nil(terminal) and action in [:llm_turn, :tool_result, :failed] do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end

  defp handle(input, action, context) do
    result = decide(input, action, context)
    result = if action == :ask, do: bind_scope(result, input), else: result

    result =
      case result do
        {:ok, %{state: %{status: :completed} = state} = result} ->
          {:ok,
           %{
             result
             | state:
                 apply_todo_gate(
                   state,
                   (input.context.aikido[:agent] && input.context.aikido.agent.state) || %{}
                 )
           }}

        other ->
          other
      end

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

        payload =
          Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])

        payload =
          if action == :llm_turn,
            do: Map.put(payload, :turn, Map.from_struct(input.arguments.turn)),
            else: payload

        Aikido.Hooks.transition(result, event, payload)

      _ ->
        result
    end
  end

  defp run_message(input, :message, _context) do
    state = input.arguments.state

    if state.status == :waiting do
      case ask_open_run(
             %{
               query: input.arguments.text,
               request_id: state.request_id,
               metadata: Map.get(state, :run_metadata, %{})
             },
             state
           ) do
        {:ok, result} ->
          Aikido.Hooks.transition(bind_scope({:ok, result}, input), :run_started, %{
            query: input.arguments.text
          })

        error ->
          error
      end
    else
      state =
        Map.update(
          state,
          :queued_messages,
          [input.arguments.text],
          &(&1 ++ [input.arguments.text])
        )

      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp run_message(input, :deliver, _context) do
    if input.arguments.state.status in [:setup, :running] do
      state =
        input.arguments.state
        |> Map.update(:queued_messages, [input.arguments.text], &(&1 ++ [input.arguments.text]))
        |> Map.update(:run_metadata, %{}, fn metadata ->
          delivery = Map.take(input.arguments, [:request_id, :metadata])
          Map.update(metadata, :deliveries, [delivery], &(&1 ++ [delivery]))
        end)

      Aikido.Types.ActionResult.new(state: state)
    else
      case ask_open_run(
             %{
               query: input.arguments.text,
               request_id: input.arguments.request_id,
               metadata: input.arguments.metadata
             },
             input.arguments.state
           ) do
        {:ok, result} ->
          Aikido.Hooks.transition(bind_scope({:ok, result}, input), :run_started, %{
            query: input.arguments.text
          })

        error ->
          error
      end
    end
  end

  defp bind_scope({:ok, result}, input),
    do: {:ok, %{result | state: Map.put(result.state, :run_scope, caller_scope(input))}}

  defp bind_scope(error, _input), do: error

  defp caller_scope(input),
    do: Map.merge(%{actor: nil, tenant: nil}, Map.take(input.context.aikido, [:actor, :tenant]))

  defp decide(input, :ask, _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    if ask_running?(slice) do
      {:error, :busy}
    else
      ask_open_run(data, slice)
    end
  end

  defp decide(input, :cancel, _context) do
    signal = input.context.aikido.signal
    slice = input.arguments.state
    requested = Map.get(signal.data, :request_id)

    if slice.status in [:setup, :running, :waiting] &&
         (is_nil(requested) || requested == slice.request_id) do
      Aikido.Types.ActionResult.new(
        state:
          slice
          |> Map.put(:status, :failed)
          |> Map.put(:error, :cancelled)
          |> Map.put(:hooks_pending, %{}),
        directives: []
      )
    else
      Aikido.Types.ActionResult.new(state: slice, directives: [])
    end
  end

  defp decide(input, :failed, _context) do
    reason = input.arguments[:reason]
    id = input.arguments[:request_id]
    slice = input.arguments.state

    cond do
      slice.request_id != id ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      slice.status not in [:setup, :running] || not is_nil(Map.get(slice, :handoff_pending)) ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      true ->
        Aikido.Types.ActionResult.new(
          state:
            slice
            |> Map.put(:status, :failed)
            |> Map.put(:error, reason)
            |> Map.put(:hooks_pending, %{}),
          directives: []
        )
    end
  end

  defp decide(input, :llm_turn, _context) do
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

        llm_turn_handle_turn(
          response,
          turn,
          Map.merge(slice, %{
            usage: usage,
            last_input_tokens: Aikido.AI.Handoff.input_tokens(ReqLLM.Response.usage(response)),
            streaming_text: turn.text,
            streaming_thinking: turn.thinking,
            stream_attempt: 0
          })
        )
    end
  end

  defp decide(input, :tool_result, _context) do
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
        tool_result_append_and_maybe_dispatch(data, slice)
    end
  end

  defp ask_open_run(data, slice) do
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
      ask_build_run(
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

  defp ask_build_run(
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
          context = Conversation.close_tool_calls(context)
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
        else: Conversation.replace_context(base, context)

    base =
      Conversation.append_messages(
        base,
        Enum.map(Map.get(base, :queued_messages, []) ++ [data.query], &ReqLLM.Context.user/1)
      )

    context = base.context

    options = data[:options] || Map.get(slice, :options) || %Aikido.AI.Options{}

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

    directive = %Aikido.Slices.AiReact.Directives.LLMCall{
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

  defp ask_running?(%{status: status}) when status in [:setup, :running] do
    true
  end

  defp ask_running?(_) do
    false
  end

  defp llm_turn_handle_turn(response, %{type: :final_answer, text: text}, slice) do
    slice = Conversation.append_message(slice, response.message)
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
        Conversation.append_messages(new_slice, Enum.map(queued, &ReqLLM.Context.user/1))

      context = new_slice.context

      new_slice =
        Map.merge(new_slice, %{
          status: :running,
          result: nil,
          context: context,
          queued_messages: [],
          streaming_text: "",
          streaming_thinking: ""
        })

      effect = %Aikido.Slices.AiReact.Directives.LLMCall{
        client: Map.get(slice, :client, ReqLLM.Generation),
        model: slice.model,
        context: context,
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

  defp llm_turn_handle_turn(
         response,
         %{type: :tool_calls, tool_calls: tool_calls, text: text},
         slice
       ) do
    iteration = slice.iteration + 1

    msg_calls = Enum.reject(tool_calls, &ReqLLM.ToolCall.flagged_builtin?/1)

    if msg_calls == [] do
      llm_turn_handle_turn(response, %{type: :final_answer, text: text}, slice)
    else
      slice = Conversation.append_message(slice, response.message)
      new_context = slice.context

      if iteration >= slice.max_iterations do
        llm_turn_truncate(slice, new_context, iteration)
      else
        llm_turn_dispatch_tools(slice, new_context, iteration, msg_calls)
      end
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

    Aikido.Types.ActionResult.new(state: new_slice, directives: [])
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
          options: Map.get(slice, :options, %{}),
          tool_call: call,
          tool_context: Map.get(slice, :tool_context, %{}),
          request_id: slice.request_id
        }
      end)

    Aikido.Types.ActionResult.new(state: new_slice, directives: directives)
  end

  defp tool_result_append_and_maybe_dispatch(data, slice) do
    msg = ReqLLM.Context.tool_result(data.tool_call_id, data.name, data.content)
    slice = Conversation.append_message(slice, msg)
    new_context = slice.context

    received =
      slice.tool_results_received ++
        [%{tool_call_id: data.tool_call_id, name: data.name, content: data.content}]

    if length(received) == length(slice.pending_tool_calls) do
      tool_result_finalize_batch(slice)
    else
      Aikido.Types.ActionResult.new(
        state: %{slice | context: new_context, tool_results_received: received},
        directives: []
      )
    end
  end

  defp tool_result_finalize_batch(slice) do
    current_signature = Aikido.Slices.AiReact.tool_call_signature(slice.pending_tool_calls)

    slice =
      tool_result_maybe_append_cycle_warning(
        slice,
        slice.previous_tool_signature,
        current_signature
      )

    slice =
      Conversation.append_messages(
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

    directive = %Aikido.Slices.AiReact.Directives.LLMCall{
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

  defp tool_result_maybe_append_cycle_warning(state, previous_signature, current_signature)
       when is_binary(previous_signature) and previous_signature == current_signature do
    Conversation.append_message(
      state,
      ReqLLM.Context.user(Aikido.Slices.AiReact.cycle_warning())
    )
  end

  defp tool_result_maybe_append_cycle_warning(state, _previous, _current) do
    state
  end

  defp apply_todo_gate(state, agent_state) do
    options = Map.get(state, :options) || %Aikido.AI.Options{}

    if options.completion == :todos do
      case Map.get(agent_state, options.todo_path) do
        %{items: items} ->
          blocking = Enum.filter(items, & &1.blocking?)

          cond do
            blocked = Enum.find(blocking, &(&1.status == :blocked)) ->
              Map.merge(state, %{
                status: :failed,
                error: {:todo_blocked, blocked.id, blocked.reason}
              })

            Enum.any?(blocking, &(&1.status != :completed)) ->
              Map.put(state, :status, :waiting)

            true ->
              Map.put(state, :status, :completed)
          end

        _ ->
          Map.merge(state, %{status: :failed, error: :todo_slice_not_mounted})
      end
    else
      state
    end
  end
end
