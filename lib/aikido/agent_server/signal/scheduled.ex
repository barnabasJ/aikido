defmodule Aikido.AgentServer.Signal.Scheduled do
  @moduledoc false

  use Aikido.Signal

  signal do
    type "aikido.scheduled"

    schema do
      attribute :message, :term do
        allow_nil? false
        description "The scheduled message payload"
      end
    end
  end
end
