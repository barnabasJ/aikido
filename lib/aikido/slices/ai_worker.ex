defmodule Aikido.Slices.AiWorker do
  @moduledoc "Bridges the team task protocol to an AiReact slice mounted at `:ai`.\n\nMount at a separate path, e.g. `slice :work, Aikido.Slices.AiWorker`. A task\nis accepted on `harness.task`, launches a model turn by signal, and reports\na correlated result to the assigning team. Observation is deferred to a\nseparate signal so it sees the committed AiReact transition regardless of\nrouting order. Each action writes only its own slice.\n"
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
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "accept_ai_task"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :task_id, :string, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :attempt, :string, allow_nil?: false
      argument :reply_to, :term, allow_nil?: false
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
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

  defp reduce(%{data: data}, state, _opts, context) do
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
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "observe_ai_task"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
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

  defp reduce(_signal, state, _opts, context) do
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
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "settle_ai_task"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
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

  defp reduce(signal, state, _opts, context) do
    ai = context.agent.state.ai
    pending = state.pending

    if pending && signal.data.task_id == pending.task_id && ai.request_id == pending.task_id &&
         ai.status in [:completed, :failed] do
      type =
        if ai.status == :completed do
          "aikido.ash.team.task.completed"
        else
          "aikido.ash.team.task.failed"
        end

      result =
        if ai.status == :completed do
          ai.result
        else
          ai.error
        end

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
