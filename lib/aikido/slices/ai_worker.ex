defmodule Aikido.Slices.AiWorker do
  @moduledoc """
  Bridges the team task protocol to an AiReact slice mounted at `:ai`.

  Mount at a separate path, e.g. `slice :work, Aikido.Slices.AiWorker`. A task
  is accepted on `harness.task`, launches a model turn by signal, and reports
  a correlated result to the assigning team. Observation is deferred to a
  separate signal so it sees the committed AiReact transition regardless of
  routing order. Each action writes only its own slice. Internal task signals
  target the worker directly, through direct process delivery; observe their
  processing with `Aikido.AgentServer.subscribe/4`.
  """
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "ai_worker"

    schema do
      attribute :queue, {:array, :map} do
        description "Accepted team tasks waiting for the current AI request to settle."
        public? true
        default []
      end

      attribute :pending, :term do
        description "Correlation and reply destination of the task assigned to the active AI run."
        public? true
        default nil
      end

      attribute :completed, :integer do
        description "Number of team tasks reported as completed or failed by this worker."
        public? true
        default 0
      end
    end

    route Aikido.Slices.AiWorker.Signals.Accept, Aikido.Slices.AiWorker.Accept, public?: false
    route Aikido.Slices.AiWorker.Signals.CancelTask, Aikido.Slices.AiWorker.Cancel, public?: false
    route "ai.react.**", Aikido.Slices.AiWorker.Observe
    route "aikido.todo.changed", Aikido.Slices.AiWorker.Observe, public?: false
    route Aikido.Slices.AiWorker.Signals.Settle, Aikido.Slices.AiWorker.Settle, public?: false
  end

  @doc false
  def externalize(state), do: Map.merge(state, %{pending: nil, queue: []})
  @doc false
  def reinstate(state), do: Map.merge(state, %{pending: nil, queue: []})
end
