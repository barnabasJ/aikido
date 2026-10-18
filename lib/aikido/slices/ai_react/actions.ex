defmodule Aikido.Slices.AiReact.Actions do
  @moduledoc "Native Ash state-transition actions for the ai_react slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :ask, Aikido.ActionResult do
      argument :state, :term
      argument :query, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      argument :model, :term
      argument :client, :atom
      argument :tools, {:array, :term}
      argument :system_prompt, :string
      argument :max_iterations, :integer, constraints: [min: 1]
      argument :llm_opts, Aikido.Types.Native, constraints: [kind: :keyword_list]
      description "Open a ReAct run on a Aikido.Slices.AiReact-equipped agent."
      run {Aikido.Slices.AiReact.Actions.Implementation, action: :ask}
    end

    action :cancel, Aikido.ActionResult do
      argument :state, :term
      argument :request_id, :string, default: nil
      run {Aikido.Slices.AiReact.Actions.Implementation, action: :cancel}
    end

    action :failed, Aikido.ActionResult do
      argument :state, :term
      argument :reason, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Settle the slice as :failed with the reason."
      run {Aikido.Slices.AiReact.Actions.Implementation, action: :failed}
    end

    action :llm_turn, Aikido.ActionResult do
      argument :state, :term
      argument :turn, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process a completed LLM turn and decide the next ReAct step."
      run {Aikido.Slices.AiReact.Actions.Implementation, action: :llm_turn}
    end

    action :tool_result, Aikido.ActionResult do
      argument :state, :term
      argument :tool_call_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :content, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process one tool result and fan-in to the next LLM turn."
      run {Aikido.Slices.AiReact.Actions.Implementation, action: :tool_result}
    end
  end
end
