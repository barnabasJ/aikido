defmodule Aikido.Team.Signals.TaskTimeout do
  @moduledoc "Typed payload for `aikido.ash.team.task.timeout`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.task.timeout"

    schema do
      attribute :timeout_ms, :integer do
        description "Effective deadline duration retained when the timer was scheduled."
        constraints min: 1
      end

      attribute :task_id, :string do
        description "Task whose deadline expired."
      end

      attribute :attempt, :term do
        description "Member incarnation associated with the deadline."
      end
    end
  end
end
