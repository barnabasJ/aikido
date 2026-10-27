defmodule Aikido.Ownership.Signals.ParentMonitored do
  @moduledoc "Acknowledges the monitor created for a logical parent."
  use Aikido.Signal

  signal do
    type "aikido.ownership.parent_monitored"

    schema do
      attribute :pid, :term do
        description "Parent process being monitored."
        allow_nil? false
      end

      attribute :ref, :term do
        description "New process monitor reference."
        allow_nil? false
      end
    end
  end
end
