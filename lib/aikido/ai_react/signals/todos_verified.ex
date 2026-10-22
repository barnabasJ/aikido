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

      attribute :result, :boolean do
        description "Whether the verifier accepted the proposed answer and work."
        allow_nil? false
      end
    end
  end
end
