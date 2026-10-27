defmodule Aikido.AgentServer.Signals.StopSelf do
  @moduledoc "Requests graceful termination of the receiving agent."
  use Aikido.Signal

  signal do
    type "aikido.agent.stop"

    schema do
      attribute :reason, :term do
        description "Reason supplied to the graceful stop directive."
        default :normal
      end
    end
  end
end
