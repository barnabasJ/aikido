defmodule Aikido.Team.Signals.Cleanup do
  @moduledoc "Typed payload for `aikido.ash.team.cleanup`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.cleanup"

    schema do
      attribute :result, :term do
        description "Result returned by cleanup work."
      end

      attribute :reason, :term do
        description "Failure reason returned by cleanup work."
      end
    end
  end
end
