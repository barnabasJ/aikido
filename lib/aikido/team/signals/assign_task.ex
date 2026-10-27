defmodule Aikido.Team.Signals.AssignTask do
  @moduledoc "Typed payload for `aikido.ash.team.assign_task`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.assign_task"

    schema do
      attribute :member, :term do
        description "Topology name of the member to operate on."
        allow_nil? false
      end

      attribute :task_id, :string do
        description "Stable identifier for the delegated task."
      end

      attribute :type, :string do
        description "Signal type delivered to the target member."
        default "harness.task"
      end

      attribute :payload, :map do
        description "Arguments carried by the delivered signal."
        default %{}
      end

      attribute :timeout_ms, :integer do
        description "Maximum duration allowed for this delegated task, in milliseconds."
        default 30_000
        constraints min: 1
      end

      attribute :worker_lifecycle, Aikido.Team.Types.WorkerLifecycle do
        description "Whether to retain the worker after its assigned task finishes."
        default :keep
      end

      attribute :mode, Aikido.Team.Types.DelegationMode do
        description "Foreground work holds a requester dependency; background work delivers its result later."
        default :background
        allow_nil? false
      end

      attribute :requester, :term do
        description "Requesting member name, or :self for the coordinating team agent."
      end

      attribute :notify, :term do
        description "Member name to receive task results, :self for this team, or nil for no notification."
      end

      attribute :metadata, :map do
        description "Caller metadata retained with the delegated task and its result."
        default %{}
      end
    end
  end
end
