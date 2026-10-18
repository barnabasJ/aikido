defmodule Aikido.Slices.AiWorker do
  @moduledoc """
  Bridges the team task protocol to an AiReact slice mounted at `:ai`.

  Mount at a separate path, e.g. `slice :work, Aikido.Slices.AiWorker`. A task
  is accepted on `harness.task`, launches a model turn by signal, and reports
  a correlated result to the assigning team. Observation is deferred to a
  separate signal so it sees the committed AiReact transition regardless of
  routing order. Each action writes only its own slice.
  """
  use Aikido.Slice

  slice do
    name "ai_worker"

    schema do
      attribute :pending, :term, default: nil
      attribute :completed, :integer, default: 0
    end
  end

  signal_routes do
    route "harness.task", Aikido.Slices.AiWorker.Accept
    route "ai.react.**", Aikido.Slices.AiWorker.Observe
    route "harness.ai.observe", Aikido.Slices.AiWorker.Settle
  end
end

defmodule Aikido.Slices.AiWorker.Accept do
  @moduledoc false
  use Aikido.Action

  action do
    name "accept_ai_task"

    schema do
      attribute :task_id, :string, allow_nil?: false
      attribute :member, :term, allow_nil?: false
      attribute :attempt, :string, allow_nil?: false
      attribute :reply_to, :term, allow_nil?: false
      attribute :text, :string, allow_nil?: false
    end
  end

  def run(%{data: data}, state, _opts, context) do
    if state.pending || context.agent.state.ai.status == :running do
      failure =
        Jido.Signal.new!(
          "aikido.ash.team.task.failed",
          Map.merge(Map.take(data, [:task_id, :member, :attempt]), %{reason: :busy})
        )

      {:ok, state, [Aikido.Directives.emit_to_pid(failure, data.reply_to)]}
    else
      pending = Map.take(data, [:task_id, :member, :attempt, :reply_to])

      payload =
        data
        |> Map.take([:model, :client, :tools, :system_prompt, :llm_opts, :max_iterations])
        |> Map.merge(%{query: data.text, request_id: data.task_id})

      ask = Jido.Signal.new!("ai.react.ask", payload)
      {:ok, %{state | pending: pending}, [Aikido.Directives.emit_to_pid(ask, context.agent_pid)]}
    end
  end
end

defmodule Aikido.Slices.AiWorker.Observe do
  @moduledoc false
  use Aikido.Action

  action do
    name "observe_ai_task"

    schema do
    end
  end

  def run(_signal, state, _opts, context) do
    if state.pending do
      observe = Jido.Signal.new!("harness.ai.observe", %{task_id: state.pending.task_id})
      {:ok, state, [Aikido.Directives.emit_to_pid(observe, context.agent_pid)]}
    else
      {:ok, state, []}
    end
  end
end

defmodule Aikido.Slices.AiWorker.Settle do
  @moduledoc false
  use Aikido.Action

  action do
    name "settle_ai_task"

    schema do
    end
  end

  def run(signal, state, _opts, context) do
    ai = context.agent.state.ai
    pending = state.pending

    if pending && signal.data.task_id == pending.task_id && ai.request_id == pending.task_id &&
         ai.status in [:completed, :failed] do
      type =
        if ai.status == :completed,
          do: "aikido.ash.team.task.completed",
          else: "aikido.ash.team.task.failed"

      result = if ai.status == :completed, do: ai.result, else: ai.error

      reply =
        Jido.Signal.new!(
          type,
          Map.merge(Map.take(pending, [:task_id, :member, :attempt]), %{result: result})
        )

      {:ok, %{state | pending: nil, completed: state.completed + 1},
       [Aikido.Directives.emit_to_pid(reply, pending.reply_to)]}
    else
      {:ok, state, []}
    end
  end
end
