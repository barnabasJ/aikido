defmodule Aikido.AiReact.Signals.TodosVerified do
  @moduledoc "Correlated result of the application-owned todo verifier."
  use Aikido.Signal

  signal do
    type "ai.react.todos.verified"

    schema do
      attribute :revision, :integer do
        description "Todo revision inspected by this verification; newer work invalidates its verdict."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Run whose answer was verified."
        allow_nil? false
      end

      attribute :iteration, :integer do
        description "Model iteration whose answer was verified."
        allow_nil? false
      end

      attribute :final_answer?, :boolean do
        description "Whether the verdict originates from a newly adopted model final answer."
        default false
        allow_nil? false
      end

      attribute :result, Aikido.AiReact.Types.TodoVerificationResult do
        description "Native boolean verdict or typed application verification feedback and private data."
        allow_nil? false
      end
    end
  end
end
