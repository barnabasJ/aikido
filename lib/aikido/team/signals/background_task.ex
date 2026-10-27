defmodule Aikido.Team.Signals.BackgroundTask do
  @moduledoc "Typed payload for `aikido.ash.team.background_task`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.background_task"

    schema do
      attribute :task_id, :string do
        description "Existing task whose caller should stop waiting, without cancelling the worker."
        allow_nil? false
      end
    end
  end
end
