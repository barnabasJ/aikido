defmodule Aikido.Slices.AiWorker.Accept.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    data = Map.delete(input.arguments, :state)
    state = input.arguments.state
    context = input.context.aikido

    if state.pending || context.agent.state.ai.status == :running do
      failure =
        Jido.Signal.new!(
          "aikido.ash.team.task.failed",
          Map.merge(Map.take(data, [:task_id, :member, :attempt]), %{reason: :busy})
        )

      Aikido.ActionResult.new(
        state: state,
        directives: [Aikido.Directives.emit_to_pid(failure, data.reply_to)]
      )
    else
      pending = Map.take(data, [:task_id, :member, :attempt, :reply_to])

      payload =
        data
        |> Map.take([:model, :client, :tools, :system_prompt, :llm_opts, :max_iterations])
        |> Map.merge(%{query: data.text, request_id: data.task_id})

      ask = Jido.Signal.new!("ai.react.ask", payload)

      Aikido.ActionResult.new(
        state: %{state | pending: pending},
        directives: [Aikido.Directives.emit_to_pid(ask, context.agent_pid)]
      )
    end
  end
end
