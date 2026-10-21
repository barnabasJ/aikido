defmodule Aikido.AgentServer.Types.Status do
  @moduledoc "Process lifecycle states of an AgentServer."
  use Ash.Type.Enum,
    values: [
      initializing: "The runtime is initializing.",
      idle: "The runtime is ready to handle signals.",
      stopping: "The runtime is stopping."
    ]
end
