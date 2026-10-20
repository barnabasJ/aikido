defmodule Aikido.Signals.AiWorker.Settle do
  @moduledoc "Typed payload for `harness.ai.observe`."
  use Aikido.Signal

  signal do
    type "harness.ai.observe"
  end
end
