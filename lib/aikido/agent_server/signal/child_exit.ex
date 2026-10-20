defmodule Aikido.AgentServer.Signal.ChildExit do
  @moduledoc false

  use Aikido.Signal

  signal do
    type "aikido.agent.child.exit"

    schema do
      attribute :tag, :term,
        allow_nil?: false,
        description: "Tag assigned to the child when spawned"

      attribute :pid, :term,
        allow_nil?: false,
        description: "PID of the child process that exited"

      attribute :reason, :term,
        allow_nil?: false,
        description: "Exit reason from the child process"
    end
  end
end
