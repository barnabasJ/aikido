defmodule Aikido.Team.Signals.StopMonitored do
  @moduledoc "Native monitor registration for a tracked stop target."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.stop_monitored"

    schema do
      attribute :operation_id, :string do
        description "Existing lifecycle operation owning this monitor."
        allow_nil? false
      end

      attribute :member, :term do
        description "Member whose exact incarnation is monitored."
        allow_nil? false
      end

      attribute :pid, :term do
        description "Monitored process incarnation."
        allow_nil? false
      end

      attribute :ref, :term do
        description "Native BEAM monitor reference."
        allow_nil? false
      end
    end
  end
end
