defmodule Aikido.Ownership.Signals.ChildMonitored do
  @moduledoc "Acknowledges the process monitor installed for an owned child."
  use Aikido.Signal

  signal do
    type "aikido.ownership.child.monitored"

    schema do
      attribute :tag, :term do
        description "Topology tag whose child is being monitored."
        allow_nil? false
      end

      attribute :pid, :term do
        description "Child process monitored by the owner."
        allow_nil? false
      end

      attribute :ref, :term do
        description "Monitor reference created in the owner's process."
        allow_nil? false
      end
    end
  end
end
