defmodule Aikido.AiWorker.Actions.Accept do
  @moduledoc """
  Pure reducer that accepts a correlated team task and its caller scope.

  Ignores duplicate task IDs, queues work while AI is busy, or returns updated
  worker state and an `Emit` directive starting an AI request on the owning agent.
  Tasks without an effective model fail immediately through the team reply protocol.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    data = Map.delete(input.arguments, :state)
    state = input.arguments.state
    context = input.context.aikido
    scope = Map.merge(%{actor: nil, tenant: nil}, Aikido.Signal.ctx(context.signal))
    data = Map.put(data, :signal_context, scope)

    duplicate? =
      (state.pending && state.pending.task_id == data.task_id) ||
        Enum.any?(Map.get(state, :queue, []), &(&1.task_id == data.task_id))

    cond do
      duplicate? ->
        Aikido.Types.ActionResult.new(state: state)

      state.pending || context.agent.state.ai.status in [:setup, :running, :waiting] ->
        Aikido.Types.ActionResult.new(state: Map.update(state, :queue, [data], &(&1 ++ [data])))

      true ->
        start_task(state, data, context)
    end
  end

  @doc false
  def start_task(state, data, context) do
    if is_nil(data[:model] || context.agent.state.ai.model) do
      Aikido.AiWorker.Actions.Settle.complete_task(
        state,
        data,
        :failed,
        :no_model,
        context
      )
    else
      launch_task(state, data, context)
    end
  end

  defp launch_task(state, data, context) do
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
      %Aikido.Signal{id: nil, type: "ai.react.ask", data: payload, source: "/aikido"}
      |> Aikido.Signal.put_ctx(Map.get(data, :signal_context, %{}))

    Aikido.Types.ActionResult.new(
      state: %{state | pending: pending},
      directives: [Aikido.Directives.emit_to_pid(ask, context.agent_pid)]
    )
  end
end
