defmodule Aikido.Slices.AiWorker do
  @moduledoc """
  Bridges the team task protocol to an AiReact slice mounted at `:ai`.

  Mount at a separate path, e.g. `slice :work, Aikido.Slices.AiWorker`. A task
  is accepted on `harness.task`, launches a model turn by signal, and reports
  a correlated result to the assigning team. Observation is deferred to a
  separate signal so it sees the committed AiReact transition regardless of
  routing order. Each action writes only its own slice.
  """
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "ai_worker"

    schema do
      attribute :pending, :term, public?: true, default: nil
      attribute :completed, :integer, public?: true, default: 0
    end

    route "harness.task", :accept
    route "ai.react.**", :observe
    route "harness.ai.observe", :settle
  end

  actions do
    action :accept, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :task_id, :string, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :attempt, :string, allow_nil?: false
      argument :reply_to, :term, allow_nil?: false
      argument :text, :string, allow_nil?: false
      argument :model, :term
      argument :client, :atom
      argument :tools, {:array, :term}
      argument :system_prompt, :string
      argument :llm_opts, Aikido.Types.Native, constraints: [kind: :keyword_list]
      argument :max_iterations, :integer, constraints: [min: 1]
      run Aikido.Slices.AiWorker.Accept
    end

    action :observe, Aikido.ActionResult do
      public? false
      argument :state, :term
      run Aikido.Slices.AiWorker.Observe
    end

    action :settle, Aikido.ActionResult do
      public? false
      argument :state, :term
      run Aikido.Slices.AiWorker.Settle
    end
  end
end
