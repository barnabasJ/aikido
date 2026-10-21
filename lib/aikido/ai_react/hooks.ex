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

  @doc false
  def transition({:ok, result}, event, payload) do
    state = result.state

    state =
      Map.put(
        state,
        :hook_terminal,
        if(state.status in [:completed, :failed], do: state.status)
      )

    queue =
      [{:event, event, payload}] ++ Enum.flat_map(result.directives, &hook_steps_for_effect/1)

    queue =
      if state.status == :completed,
        do: queue ++ [{:event, :run_completed, %{result: state.result}}],
        else: queue

    queue =
      if state.status == :failed && event not in [:run_failed, :run_cancelled],
        do: queue ++ [{:event, :run_failed, %{reason: state.error}}],
        else: queue

    case {state.status, Map.to_list(state.hooks_pending)} do
      {status, [{token, continuation}]} when status != :failed ->
        continuation = %{continuation | queue: continuation.queue ++ queue, status: status}

        Aikido.Types.ActionResult.new(
          state:
            state
            |> Map.put(:hooks_pending, %{token => continuation})
            |> Map.put(:status, if(status == :setup, do: :setup, else: :running))
        )

      _ ->
        advance(Map.put(state, :hooks_pending, %{}), queue, state.status, [])
    end
  end

  def transition(error, _event, _payload), do: error

  @doc "Run before-model hooks, then release this model request with their accumulated context."
  def before_model(state, %LLMCall{} = directive) do
    advance(state, hook_steps_for_effect(directive), state.status, [])
  end

  defp hook_steps_for_effect(%LLMCall{} = effect),
    do: [{:event, :before_model, %{}}, {:effect, effect}]

  defp hook_steps_for_effect(%ToolExec{} = effect),
    do: [{:event, :before_tool, %{tool_call: effect.tool_call}}, {:effect, effect}]

  defp hook_steps_for_effect(effect), do: [{:effect, effect}]

  @doc false
  def advance(state, [], status, directives) do
    state = state |> Map.put(:status, status) |> Map.put(:hook_terminal, nil)
    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end

  def advance(state, [{:event, event, payload} | rest], status, directives) do
    hooks = Enum.filter(state.hooks, &(&1.event == event))

    event =
      Map.merge(payload, %{
        type: event,
        request_id: state.request_id,
        iteration: state.iteration,
        metadata: Map.get(state, :run_metadata, %{})
      })

    queue = Enum.map(hooks, &{:hook, &1, event}) ++ rest
    advance(state, queue, status, directives)
  end

  def advance(state, [{:hook, hook, event} | rest], status, directives) do
    token = Map.get(state, :hook_sequence, 0) + 1
    state = Map.put(state, :hook_sequence, token)
    effect = %ExecuteHook{hook: hook, event: event, token: token, request_id: state.request_id}

    if hook.mode == :async do
      advance(state, rest, status, directives ++ [effect])
    else
      pending = Map.get(state, :hooks_pending, %{})

      state =
        state
        |> Map.put(:hooks_pending, Map.put(pending, token, %{queue: rest, status: status}))
        |> Map.put(:status, if(status == :setup, do: :setup, else: :running))

      Aikido.Types.ActionResult.new(state: state, directives: directives ++ [effect])
    end
  end

  def advance(state, [{:effect, %LLMCall{} = effect} | rest], status, directives) do
    state =
      Aikido.AiReact.Context.append_messages(
        state,
        Enum.map(state.queued_messages, &ReqLLM.Context.user/1)
      )

    state = %{state | queued_messages: []}
    {state, effect} = apply_hook_context(state, effect)
    {state, effect} = Aikido.AiReact.Handoff.before_model(state, effect)
    advance(state, rest, status, directives ++ [effect])
  end

  def advance(state, [{:effect, effect} | rest], status, directives),
    do: advance(state, rest, status, directives ++ [effect])

  defp apply_hook_context(state, effect) do
    state =
      Enum.reduce(Map.get(state, :hook_context, []), state, fn entry, state ->
        Aikido.AiReact.Context.append_message(
          state,
          ReqLLM.Context.user("""
          [Hook context: #{entry.name}]
          #{entry.text}\
          """)
        )
      end)

    state = Map.put(state, :hook_context, [])
    {state, %{effect | context: state.context}}
  end

  @doc false
  def enqueue_context(state, name, text),
    do:
      Map.put(
        state,
        :hook_context,
        Map.get(state, :hook_context, []) ++ [%{name: name, text: text}]
      )
end
