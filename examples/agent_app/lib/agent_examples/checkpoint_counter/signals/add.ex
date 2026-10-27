defmodule AgentExamples.CheckpointCounter.Signals.Add do
  @moduledoc "Payload for the checkpoint counter add command."
  use Aikido.Signal

  signal do
    type "examples.checkpoint_counter.add"

    schema do
      attribute :amount, :integer do
        description "Amount added to the recoverable counter."
        allow_nil? false
      end
    end
  end
end
