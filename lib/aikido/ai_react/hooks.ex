defmodule Aikido.AiReact.Hooks do
  @moduledoc """
  Pure lifecycle planning for Lua hooks. Actions own queues and decisions;
  `Aikido.AiReact.Directives.ExecuteHook` evaluates one script outside the agent mailbox.

  Hooks run in declaration order at each event. Sync hooks hold that event's
  continuation; incoming event continuations queue behind a pending sync hook.
  Async hooks observe independently. A sync denial or error fails the run.
  Async errors are recorded without stopping the run.
  """
  alias Aikido.AiReact.Directives.ExecuteHook
  alias Aikido.AiReact.Directives.{LLMCall, ToolExec}

  @doc "Queue lifecycle hooks only when an action changed its state; preserve errors and no-ops."
  def queue_event_hooks_if_changed({:ok, %{state: state}} = result, input, event, payload)
      when state != input.arguments.state,
      do: queue_event_hooks(result, event, payload)

  def queue_event_hooks_if_changed(result, _input, _event, _payload), do: result

  @doc "Queue an event, its directive hooks and any terminal event in declaration order."
  def queue_event_hooks({:ok, result}, event, payload) do
    queue = event_steps(result, event, payload)

    result.state
    |> mark_terminal_transition()
    |> enqueue_event_steps(queue)
  end

  def queue_event_hooks(error, _event, _payload), do: error

  defp event_steps(result, event, payload) do
    [{:event, event, payload}] ++
      Enum.flat_map(result.directives, &hook_steps_for_effect/1) ++
      terminal_event_steps(result.state, event)
  end

  defp terminal_event_steps(%{status: :completed} = state, _event),
    do: [{:event, :run_completed, %{result: state.result}}]

  defp terminal_event_steps(%{status: :failed} = state, event)
       when event not in [:run_failed, :run_cancelled],
       do: [{:event, :run_failed, %{reason: state.error}}]

  defp terminal_event_steps(_state, _event), do: []

  defp mark_terminal_transition(state) do
    Map.put(state, :hook_terminal, if(state.status in [:completed, :failed], do: state.status))
  end

  defp enqueue_event_steps(state, queue) do
    case {state.status, Map.to_list(state.hooks_pending)} do
      {status, [{token, continuation}]} when status != :failed ->
        continuation = %{continuation | queue: continuation.queue ++ queue, status: status}

        state =
          state
          |> Map.put(:hooks_pending, %{token => continuation})
          |> Map.put(:status, if(status == :setup, do: :setup, else: :running))

        Aikido.Types.ActionResult.new(state: state)

      _ ->
        state
        |> Map.put(:hooks_pending, %{})
        |> release_queued_steps(queue, state.status, [])
    end
  end

  @doc "Run before-model hooks, then release this model request with their accumulated context."
  def queue_before_model_hooks(state, %LLMCall{} = directive) do
    release_queued_steps(state, hook_steps_for_effect(directive), state.status, [])
  end

  defp hook_steps_for_effect(%LLMCall{} = effect),
    do: [{:event, :before_model, %{}}, {:effect, effect}]

  defp hook_steps_for_effect(%ToolExec{} = effect),
    do: [{:event, :before_tool, %{tool_call: effect.tool_call}}, {:effect, effect}]

  defp hook_steps_for_effect(effect), do: [{:effect, effect}]

  @doc "Release queued effects until a synchronous hook needs to return its decision."
  def release_queued_steps(state, [], status, directives) do
    state = state |> Map.put(:status, status) |> Map.put(:hook_terminal, nil)
    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end

  def release_queued_steps(state, [{:event, event, payload} | rest], status, directives) do
    hooks = Enum.filter(state.hooks, &(&1.event == event))

    event =
      Map.merge(payload, %{
        type: event,
        request_id: state.request_id,
        iteration: state.iteration,
        metadata: Map.get(state, :run_metadata, %{})
      })

    queue = Enum.map(hooks, &{:hook, &1, event}) ++ rest
    release_queued_steps(state, queue, status, directives)
  end

  def release_queued_steps(state, [{:hook, hook, event} | rest], status, directives) do
    token = Map.get(state, :hook_sequence, 0) + 1
    state = Map.put(state, :hook_sequence, token)
    effect = %ExecuteHook{hook: hook, event: event, token: token, request_id: state.request_id}

    if hook.mode == :async do
      release_queued_steps(state, rest, status, directives ++ [effect])
    else
      pending = Map.get(state, :hooks_pending, %{})

      state =
        state
        |> Map.put(:hooks_pending, Map.put(pending, token, %{queue: rest, status: status}))
        |> Map.put(:status, if(status == :setup, do: :setup, else: :running))

      Aikido.Types.ActionResult.new(state: state, directives: directives ++ [effect])
    end
  end

  def release_queued_steps(state, [{:effect, %LLMCall{} = effect} | rest], status, directives) do
    state = state |> append_queued_text_to_conversation() |> append_hook_text_to_conversation()
    effect = %{effect | context: state.context}

    {state, effect} =
      if Aikido.AiReact.Handoff.required?(state, effect),
        do: Aikido.AiReact.Handoff.prepare_request(state, effect),
        else: {state, effect}

    release_queued_steps(state, rest, status, directives ++ [effect])
  end

  def release_queued_steps(state, [{:effect, effect} | rest], status, directives),
    do: release_queued_steps(state, rest, status, directives ++ [effect])

  @doc "Append queued user messages to the conversation and empty their queue."
  def append_queued_text_to_conversation(state) do
    messages = Enum.map(state.queued_messages, &ReqLLM.Context.user/1)

    state
    |> Aikido.AiReact.Context.append_messages(messages)
    |> Map.put(:queued_messages, [])
  end

  @doc "Append hook-supplied context to the conversation and empty its queue."
  def append_hook_text_to_conversation(state) do
    state
    |> Map.get(:hook_context, [])
    |> Enum.reduce(state, &append_hook_message/2)
    |> Map.put(:hook_context, [])
  end

  defp append_hook_message(entry, state) do
    Aikido.AiReact.Context.append_message(
      state,
      ReqLLM.Context.user("""
      [Hook context: #{entry.name}]
      #{entry.text}\
      """)
    )
  end

  @doc false
  def queue_hook_text_for_next_model_request(state, name, text),
    do:
      Map.put(
        state,
        :hook_context,
        Map.get(state, :hook_context, []) ++ [%{name: name, text: text}]
      )
end
