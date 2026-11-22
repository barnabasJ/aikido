defmodule Aikido.Team.Signals.Timeout do
  @moduledoc "Typed payload for `aikido.ash.team.timeout`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.timeout"

    schema do
      attribute :timeout_ms, :integer do
        description "Effective deadline duration retained when the timer was scheduled."
        constraints min: 1
      end

      attribute :operation_id, :string do
        description "Lifecycle operation whose deadline expired."
      end
    end
  end
end
