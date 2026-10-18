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
      argument :model, :term
      argument :client, :atom
      argument :tools, {:array, :term}
      argument :system_prompt, :string
      argument :llm_opts, Aikido.Types.Native, constraints: [kind: :keyword_list]
      argument :max_iterations, :integer, constraints: [min: 1]
      run Aikido.Slices.AiWorker.Accept.Implementation
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
      run Aikido.Slices.AiWorker.Observe.Implementation
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
      run Aikido.Slices.AiWorker.Settle.Implementation
    end
  end
end
