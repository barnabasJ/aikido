defmodule Aikido.Team.Signals.Timeout do
  @moduledoc "Typed payload for `aikido.ash.team.timeout`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.timeout"

    schema do
      attribute :operation_id, :string do
        description "Lifecycle operation whose deadline expired."
      end
    end
  end
end
