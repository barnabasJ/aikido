defmodule Aikido.Team.Signals.TaskCompleted do
  @moduledoc "Typed payload for `aikido.ash.team.task.completed`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.task.completed"

    schema do
      attribute :task_id, :string do
        description "Task whose result is being reported."
      end

      attribute :attempt, :term do
        description "Member incarnation that performed the task."
      end

      attribute :member, :term do
        description "Member that performed the task."
      end

      attribute :result, :term do
        description "Successful task result."
      end

      attribute :reason, :term do
        description "Alternative result supplied by the worker."
      end
    end
  end
end
