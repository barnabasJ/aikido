defmodule AgentExamples.CheckpointCounter.Signals.Crash do
  @moduledoc "Payload for the checkpoint counter crash command."
  use Aikido.Signal

  signal do
    type "examples.checkpoint_counter.crash"
  end
end
