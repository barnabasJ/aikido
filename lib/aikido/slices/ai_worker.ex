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

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

  slice do
    name "ai_worker"

    schema do
      attribute :queue, {:array, :map}, public?: true, default: []
      attribute :pending, :term, public?: true, default: nil
      attribute :completed, :integer, public?: true, default: 0
    end

    route "harness.task", :accept
    route "harness.cancel_task", :cancel_task
    route "ai.react.**", :observe
    route "aikido.todo.changed", :observe
    route "harness.ai.observe", :settle
  end

  actions do
    action :accept, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :task_id, :string, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :attempt, :string, allow_nil?: false
      argument :reply_to, :term, allow_nil?: false
      argument :metadata, :map, default: %{}
      argument :text, :string, allow_nil?: false
      argument :model, :term
      argument :client, :module
      argument :tool_context, :map
      argument :tools, {:array, :atom}
      argument :tool_options, {:array, :tuple}, constraints: @keyword_constraints
      argument :system_prompt, :string
      argument :llm_opts, {:array, :tuple}, constraints: @keyword_constraints
      argument :max_iterations, :integer, constraints: [min: 1]
      run Aikido.Slices.AiWorker.Accept
    end

    action :cancel_task, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :task_id, :string, allow_nil?: false
      run Aikido.Slices.AiWorker.Cancel
    end

    action :observe, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      run Aikido.Slices.AiWorker.Observe
    end

    action :settle, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      run Aikido.Slices.AiWorker.Settle
    end
  end

  @doc false
  def externalize(state), do: Map.merge(state, %{pending: nil, queue: []})
  @doc false
  def reinstate(state), do: Map.merge(state, %{pending: nil, queue: []})
end
