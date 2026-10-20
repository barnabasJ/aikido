defmodule Aikido.Signals.AiWorker.Accept do
  @moduledoc "Typed payload for `harness.task`."
  use Aikido.Signal

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

  signal do
    type "harness.task"

    schema do
      attribute :task_id, :string, allow_nil?: false

      attribute :member, :term, allow_nil?: false

      attribute :attempt, :string, allow_nil?: false

      attribute :reply_to, :term, allow_nil?: false

      attribute :metadata, :map, default: %{}

      attribute :text, :string, allow_nil?: false

      attribute :model, :term

      attribute :client, :module

      attribute :tool_context, :map

      attribute :tools, {:array, :atom}

      attribute :tool_options, {:array, :tuple}, constraints: @keyword_constraints

      attribute :system_prompt, :string

      attribute :llm_opts, {:array, :tuple}, constraints: @keyword_constraints

      attribute :max_iterations, :integer, constraints: [min: 1]
    end
  end
end
