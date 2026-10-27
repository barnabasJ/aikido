defmodule AgentExamples.CheckpointCounter.Directives.Crash do
  @moduledoc "Kill this example agent without graceful shutdown or a final checkpoint."
  use Aikido.Directive

  typed_struct do
  end

  @impl true
  def exec(_directive, _signal, _runtime) do
    Process.exit(self(), :kill)
  end
end
