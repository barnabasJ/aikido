defmodule Aikido.AgentServer.Signals.ChildStartFailed do
  @moduledoc "Reports a rejected or failed child activation to its logical parent."
  use Aikido.Signal

  signal do
    type "aikido.agent.child.start_failed"
    source "/agent"

    schema do
      attribute :tag, :term do
        description "Tag identifying the child whose activation failed."
        allow_nil? false
      end

      attribute :child_id, :string do
        description "Stable identity requested for the child."
        allow_nil? false
      end

      attribute :reason, :term do
        description "Activation, task-capacity or runtime failure returned while starting the child."
        allow_nil? false
      end
    end
  end
end
