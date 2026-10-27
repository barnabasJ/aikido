defmodule Aikido.Team.Signals.OperationCompleted do
  @moduledoc "Typed payload for `aikido.ash.team.operation.completed`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.operation.completed"

    schema do
      attribute :operation_id, :string do
        description "Lifecycle operation that completed."
      end
    end
  end
end
