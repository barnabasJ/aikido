defmodule Aikido.Hooks do
  @moduledoc """
  Pure lifecycle planning for Lua hooks. Actions own queues and decisions;
  `Aikido.Hooks.Execute` evaluates one script outside the agent mailbox.

  Hooks run in declaration order at each event. Sync hooks hold that event's
  continuation; async hooks observe it independently. A sync denial or error
  fails the run. Async errors are recorded without stopping the run.
  """
  alias Aikido.Hooks.Execute
  alias Aikido.Slices.AiReact.Directives.{LLMCall, ToolExec}

  @doc false
  def transition({:ok, result}, event, payload) do
    state = result.state

    if Map.get(state, :hooks, []) == [] do
      {:ok, result}
    else
      state =
        Map.put(
          state,
          :hook_terminal,
          if(state.status in [:completed, :failed], do: state.status)
        )

      queue = [{:event, event, payload}] ++ Enum.flat_map(result.directives, &steps/1)

      queue =
        if state.status == :completed,
          do: queue ++ [{:event, :run_completed, %{result: state.result}}],
          else: queue

      advance(state, queue, state.status, [])
    end
  end

  def transition(error, _event, _payload), do: error

  @doc false
  def completed(state, data) do
    data = Map.put(data, :result, data[:result] || {:error, data[:reason] || "hook task failed"})
    pending = Map.get(state, :hooks_pending, %{})

    cond do
      state.request_id != data.request_id ->
        Aikido.ActionResult.new(state: state)

      data.mode == :async ->
        state =
          case data.result do
            {:error, reason} -> record_error(state, data.name, reason)
            _ -> state
          end

        Aikido.ActionResult.new(state: state)

      state.status != :running || not Map.has_key?(pending, data.token) ->
        Aikido.ActionResult.new(state: state)

      true ->
        {continuation, pending} = Map.pop!(pending, data.token)
        state = Map.put(state, :hooks_pending, pending)

        case data.result do
          {:ok, %Aikido.Hooks.Decision{decision: :continue, context: context}} ->
            state = if context, do: enqueue_context(state, data.name, context), else: state
            advance(state, continuation.queue, continuation.status, [])

          {:ok, %Aikido.Hooks.Decision{decision: :deny, message: message}} ->
            fail(state, {:hook_denied, data.name, message})

          {:error, reason} ->
            fail(record_error(state, data.name, reason), {:hook_failed, data.name, reason})
        end
    end
  end

  @doc false
  def context(state, data) do
    state =
      if state.request_id == data.request_id && state.status == :running,
        do: enqueue_context(state, data[:name] || "async", data.text),
        else: state

    Aikido.ActionResult.new(state: state)
  end

  defp steps(%LLMCall{} = effect),
    do: [{:event, :before_model, %{}}, {:effect, effect}]

  defp steps(%ToolExec{} = effect),
    do: [{:event, :before_tool, %{tool_call: effect.tool_call}}, {:effect, effect}]

  defp steps(effect), do: [{:effect, effect}]

  defp advance(state, [], status, directives) do
    state = state |> Map.put(:status, status) |> Map.put(:hook_terminal, nil)
    Aikido.ActionResult.new(state: state, directives: directives)
  end

  defp advance(state, [{:event, event, payload} | rest], status, directives) do
    hooks = Enum.filter(state.hooks, &(&1.event == event))

    event =
      Map.merge(payload, %{type: event, request_id: state.request_id, iteration: state.iteration})

    queue = Enum.map(hooks, &{:hook, &1, event}) ++ rest
    advance(state, queue, status, directives)
  end

  defp advance(state, [{:hook, hook, event} | rest], status, directives) do
    token = Map.get(state, :hook_sequence, 0) + 1
    state = Map.put(state, :hook_sequence, token)
    effect = %Execute{hook: hook, event: event, token: token, request_id: state.request_id}

    if hook.mode == :async do
      advance(state, rest, status, directives ++ [effect])
    else
      pending = Map.get(state, :hooks_pending, %{})

      state =
        state
        |> Map.put(:hooks_pending, Map.put(pending, token, %{queue: rest, status: status}))
        |> Map.put(:status, :running)

      Aikido.ActionResult.new(state: state, directives: directives ++ [effect])
    end
  end

  defp advance(state, [{:effect, %LLMCall{} = effect} | rest], status, directives) do
    context =
      Enum.reduce(Map.get(state, :hook_context, []), state.context, fn entry, context ->
        ReqLLM.Context.append(
          context,
          ReqLLM.Context.user("[Hook context: #{entry.name}]\n#{entry.text}")
        )
      end)

    state = state |> Map.put(:context, context) |> Map.put(:hook_context, [])
    advance(state, rest, status, directives ++ [%{effect | context: context}])
  end

  defp advance(state, [{:effect, effect} | rest], status, directives),
    do: advance(state, rest, status, directives ++ [effect])

  defp enqueue_context(state, name, text),
    do:
      Map.put(
        state,
        :hook_context,
        Map.get(state, :hook_context, []) ++ [%{name: name, text: text}]
      )

  defp record_error(state, name, reason),
    do:
      Map.put(
        state,
        :hook_errors,
        Enum.take([%{name: name, reason: reason} | Map.get(state, :hook_errors, [])], 20)
      )

  defp fail(state, reason) do
    state =
      state
      |> Map.put(:status, :failed)
      |> Map.put(:error, reason)
      |> Map.put(:hooks_pending, %{})
      |> Map.put(:hook_terminal, nil)

    Aikido.ActionResult.new(state: state)
  end
end
