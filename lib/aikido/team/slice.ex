defmodule Aikido.Team.Slice do
  @moduledoc "Native slice owning team topology, lifecycle progress, tasks, and their actions."
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension]

  attributes do
    attribute :topology, Aikido.Team.Topology do
      description "Desired member resources, ownership and dependencies for this team."
      public? true
      allow_nil? false
      default %Aikido.Team.Topology{}
    end

    attribute :members, :map do
      description "Live member process identifiers indexed by their topology names."
      public? true
      allow_nil? false
      default %{}
    end

    attribute :incarnations, :map do
      description "Activation identities used to reject stale task results from earlier member processes."
      public? true
      allow_nil? false
      default %{}
    end

    attribute :paused, :map do
      description "Members intentionally stopped and excluded from automatic reconciliation."
      public? true
      allow_nil? false
      default %{}
    end

    attribute :failures, :map do
      description "Most recent member process exits retained for lifecycle reconciliation."
      public? true
      allow_nil? false
      default %{}
    end

    attribute :pending_tasks, :map do
      description "Task requests waiting for their target member to finish activation."
      public? true
      default %{}
    end

    attribute :recovered_tasks, {:array, :string} do
      description "Interrupted task identities awaiting failure notification after restoration."
      default []
    end

    attribute :tasks, :map do
      description "Tracked task status, results, member attempts and notification metadata."
      public? true
      allow_nil? false
      default %{}
    end

    attribute :queued_operations, {:array, Aikido.Signal} do
      description "Transient scoped topology commands waiting for the current member lifecycle operation."
      default []
      allow_nil? false
    end

    attribute :operation, :map do
      description "Current lifecycle plan, awaited member step and completion or failure outcome."
      public? true
      allow_nil? false

      default %{
        id: nil,
        status: :idle,
        remaining: [],
        awaiting: nil,
        started: [],
        stopped: [],
        error: nil
      }
    end
  end

  slice do
    name "ash_team"
    route Aikido.Team.Signals.Start, Aikido.Team.Actions.Start, name: :configure_topology
    route Aikido.Team.Signals.Reconcile, Aikido.Team.Actions.Reconcile
    route Aikido.Team.Signals.AddMember, Aikido.Team.Actions.AddMember
    route Aikido.Team.Signals.RemoveMember, Aikido.Team.Actions.RemoveMember
    route Aikido.Team.Signals.EnsureMember, Aikido.Team.Actions.EnsureMember
    route Aikido.Team.Signals.StopMember, Aikido.Team.Actions.StopMember
    route Aikido.Team.Signals.Send, Aikido.Team.Actions.Send
    route Aikido.Team.Signals.Broadcast, Aikido.Team.Actions.Broadcast
    route Aikido.Team.Signals.AssignTask, Aikido.Team.Actions.AssignTask
    route Aikido.Team.Signals.BackgroundTask, Aikido.Team.Actions.BackgroundTask
    route Aikido.Team.Signals.Cleanup, Aikido.Team.Actions.Cleanup, public?: false
    route Aikido.Team.Signals.Started, Aikido.Team.Actions.Started, public?: false
    route Aikido.Team.Signals.Stopped, Aikido.Team.Actions.Stopped, public?: false
    route Aikido.Team.Signals.Failed, Aikido.Team.Actions.Failed, public?: false
    route Aikido.Team.Signals.Timeout, Aikido.Team.Actions.Timeout, public?: false
    route Aikido.Team.Signals.RetireWorker, Aikido.Team.Actions.RetireWorker, public?: false

    route Aikido.Team.Signals.OperationCompleted, Aikido.Team.Actions.OperationCompleted,
      public?: false

    route Aikido.Team.Signals.TaskCompleted, Aikido.Team.Actions.TaskCompleted, public?: false
    route Aikido.Team.Signals.TaskFailed, Aikido.Team.Actions.TaskFailed, public?: false
    route Aikido.Team.Signals.TaskTimeout, Aikido.Team.Actions.TaskTimeout, public?: false

    route Aikido.Ownership.Signals.ChildStarted, Aikido.Team.Actions.ChildStarted, public?: false

    route Aikido.Ownership.Signals.ChildExit, Aikido.Team.Actions.ChildExit, public?: false
  end

  @doc false
  def externalize(state) do
    Map.merge(state, %{
      queued_operations: [],
      members: %{},
      incarnations: %{},
      operation: Ash.Resource.Info.attribute(__MODULE__, :operation).default
    })
  end

  @doc false
  def reinstate(state, %{fresh?: true}), do: externalize(state)

  def reinstate(state, %{fresh?: false}), do: reinstate(state)

  @doc false
  def reinstate(state) do
    state
    |> externalize()
    |> restore_pending_tasks()
    |> fail_interrupted_tasks()
  end

  defp restore_pending_tasks(state) do
    tasks =
      state
      |> Map.get(:pending_tasks, %{})
      |> Map.new(fn {id, data} -> {id, pending_task_record(id, data)} end)

    Map.put(state, :tasks, Map.merge(Map.get(state, :tasks, %{}), tasks))
  end

  defp pending_task_record(id, data) do
    %{
      id: id,
      member: data.member,
      status: :dispatched,
      result: nil,
      attempt: nil,
      notify: data[:notify],
      requester: data[:requester],
      mode: Map.get(data, :mode, :background),
      metadata: data[:metadata] || %{}
    }
  end

  defp fail_interrupted_tasks(state) do
    interrupted = for {id, task} <- state.tasks, task.status == :dispatched, do: id

    tasks =
      Map.new(state.tasks, fn {id, task} ->
        {id,
         if(id in interrupted, do: %{task | status: :failed, result: :interrupted}, else: task)}
      end)

    Map.merge(state, %{tasks: tasks, pending_tasks: %{}, recovered_tasks: interrupted})
  end
end
