defmodule Aikido.Ownership.Signals.StopChildRequested do
  @moduledoc "Requests a graceful stop for the child currently bound to a topology tag."
  use Aikido.Signal

  signal do
    type "aikido.ownership.child.stop_requested"

    schema do
      attribute :tag, :term do
        description "Topology tag of the child to stop."
        allow_nil? false
      end

      attribute :reason, :term do
        description "Shutdown reason supplied by the owner."
        default :normal
        allow_nil? false
      end
    end
  end
end
