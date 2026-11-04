defmodule Aikido.Team.Signals.Inherited do
  @moduledoc "Correlated completion of a member's own and nested inherited configuration."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.inherited"

    schema do
      attribute :operation_id, :string do
        description "Coordinating team's tracked operation identity."
        allow_nil? false
      end

      attribute :member, :term do
        description "Member whose recursive inheritance step has completed or failed."
        allow_nil? false
      end

      attribute :error, :string do
        description "Public failure explanation, or nil for successful adoption."
        constraints max_length: 4096
      end
    end
  end
end
