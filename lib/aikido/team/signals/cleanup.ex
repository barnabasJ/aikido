defmodule Aikido.Team.Signals.Cleanup do
  @moduledoc "Typed payload for `aikido.ash.team.cleanup`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.cleanup"

    schema do
      attribute :member, :term do
        description "Member whose late incarnation requested cleanup."
      end

      attribute :operation_id, :string do
        description "Original activation operation of the late incarnation."
      end

      attribute :pid, :term do
        description "Exact late process incarnation."
      end

      attribute :result, :term do
        description "Result returned by cleanup work."
      end

      attribute :reason, :term do
        description "Failure reason returned by cleanup work."
      end
    end
  end
end
