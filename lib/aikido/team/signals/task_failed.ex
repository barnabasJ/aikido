defmodule Aikido.Team.Signals.TaskFailed do
  @moduledoc "Typed payload for `aikido.ash.team.task.failed`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.task.failed"

    schema do
      attribute :task_id, :string do
        description "Task whose failure is being reported."
      end

      attribute :attempt, :term do
        description "Member incarnation that performed the task."
      end

      attribute :member, :term do
        description "Member that performed the task."
      end

      attribute :result, :term do
        description "Failure result supplied by the worker."
      end

      attribute :reason, :term do
        description "Failure reason supplied by the worker."
      end
    end
  end
end
