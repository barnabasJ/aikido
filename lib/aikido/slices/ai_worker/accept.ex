defmodule Aikido.Slices.AiWorker.Accept do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    data = Map.delete(input.arguments, :state)
    state = input.arguments.state
    context = input.context.aikido
    scope = Map.merge(%{actor: nil, tenant: nil}, Aikido.SignalCtx.ctx(context.signal))
    data = Map.put(data, :signal_context, scope)

    duplicate? =
      (state.pending && state.pending.task_id == data.task_id) ||
        Enum.any?(Map.get(state, :queue, []), &(&1.task_id == data.task_id))

    cond do
      duplicate? ->
        Aikido.ActionResult.new(state: state)

      state.pending || context.agent.state.ai.status in [:running, :waiting] ->
        Aikido.ActionResult.new(state: Map.update(state, :queue, [data], &(&1 ++ [data])))

      true ->
        start_task(state, data, context)
    end
  end

  @doc false
  def start_task(state, data, context) do
    pending = Map.take(data, [:task_id, :member, :attempt, :reply_to])

    payload =
      data
      |> Map.take([
        :model,
        :client,
        :tools,
        :tool_context,
        :tool_options,
        :system_prompt,
        :llm_opts,
        :max_iterations,
        :metadata
      ])
      |> Map.merge(%{query: data.text, request_id: data.task_id})

    ask =
      Jido.Signal.new!("ai.react.ask", payload)
      |> Aikido.SignalCtx.put_ctx(Map.get(data, :signal_context, %{}))

    Aikido.ActionResult.new(
      state: %{state | pending: pending},
      directives: [Aikido.Directives.emit_to_pid(ask, context.agent_pid)]
    )
  end
end
