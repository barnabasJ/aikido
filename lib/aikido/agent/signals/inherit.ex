defmodule Aikido.Agent.Signals.Inherit do
  @moduledoc "Coordinator-correlated configuration changes adopted under the recipient's own authority."
  use Aikido.Signal

  signal do
    type "aikido.agent.inherit"

    schema do
      attribute :operation_id, :string do
        description "Parent's tracked inheritance operation identity."
        allow_nil? false
      end

      attribute :member, :term do
        description "Member name in the coordinating team's topology."
        allow_nil? false
      end

      attribute :changes, :map do
        description "Explicit inherited own-state configuration, validated by the receiving native update action."
        allow_nil? false
      end
    end
  end
end
