defmodule Aikido.AiReact.Signals.Deliver do
  @moduledoc "Text and task metadata to add to the receiving AI agent’s conversation."
  use Aikido.Signal

  signal do
    type "ai.react.deliver"

    schema do
      attribute :metadata, :map do
        description "Application metadata accompanying the delivered message."
        default %{}
      end

      attribute :text, :string do
        description "Delivered application message to append or queue for the model."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Request identifier used when delivery opens a new ReAct run."
        allow_nil? false
      end
    end
  end
end
