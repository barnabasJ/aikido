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
    route "aikido.ash.team.start", :start
    route "aikido.ash.team.reconcile", :reconcile
    route "aikido.ash.team.add_member", :add_member
    route "aikido.ash.team.remove_member", :remove_member
    route "aikido.ash.team.ensure_member", :ensure_member
    route "aikido.ash.team.stop_member", :stop_member
    route "aikido.ash.team.send", :send
    route "aikido.ash.team.broadcast", :broadcast
    route "aikido.ash.team.assign_task", :assign_task
    route "aikido.ash.team.cleanup", :cleanup
    route "aikido.ash.team.started", :started
    route "aikido.ash.team.stopped", :stopped
    route "aikido.ash.team.failed", :failed
    route "aikido.ash.team.timeout", :timeout
    route "aikido.ash.team.operation.completed", :operation_completed
    route "aikido.ash.team.retire_worker", :retire_worker
    route "aikido.ash.team.task.completed", :task_completed
    route "aikido.ash.team.task.failed", :task_failed
    route "aikido.ash.team.task.timeout", :task_timeout
    route "aikido.agent.child.started", :child_started
    route "aikido.agent.child.exit", :child_exit
  end

  actions do
    action :start, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :topology, :map
      run Aikido.Team.Actions.Start
    end

    action :reconcile, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      run Aikido.Team.Actions.Reconcile
    end

    action :add_member, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :resource, :atom
      argument :template, :atom
      argument :initial_state, :map, default: %{}
      argument :owner, :term
      argument :depends_on, {:array, :term}, default: []
      argument :activation, Aikido.Team.Types.Activation, default: :eager
      run Aikido.Team.Actions.AddMember
    end

    action :remove_member, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :cascade?, :boolean, default: false
      run Aikido.Team.Actions.RemoveMember
    end

    action :ensure_member, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :member, :term, allow_nil?: false
      run Aikido.Team.Actions.EnsureMember
    end

    action :stop_member, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :member, :term, allow_nil?: false
      run Aikido.Team.Actions.StopMember
    end

    action :send, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :type, :string, allow_nil?: false
      argument :payload, :map, default: %{}
      run Aikido.Team.Actions.Send
    end

    action :broadcast, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :type, :string, allow_nil?: false
      argument :payload, :map, default: %{}
      argument :members, {:array, :term}
      run Aikido.Team.Actions.Broadcast
    end

    action :assign_task, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :task_id, :string
      argument :type, :string, default: "harness.task"
      argument :payload, :map, default: %{}
      argument :timeout_ms, :integer, default: 30_000, constraints: [min: 1]
      argument :worker_lifecycle, Aikido.Team.Types.WorkerLifecycle, default: :keep
      argument :notify, :term
      argument :metadata, :map, default: %{}
      run Aikido.Team.Actions.AssignTask
    end

    action :cleanup, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.Cleanup
    end

    action :started, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.Started
    end

    action :stopped, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.Stopped
    end

    action :failed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.Failed
    end

    action :timeout, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.Timeout
    end

    action :retire_worker, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.RetireWorker
    end

    action :operation_completed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.OperationCompleted
    end

    action :task_completed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.TaskCompleted
    end

    action :task_failed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.TaskFailed
    end

    action :task_timeout, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.TaskTimeout
    end

    action :child_started, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.ChildStarted
    end

    action :child_exit, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Team.Actions.ChildExit
    end
  end

  @doc false
  def externalize(state), do: Map.put(state, :queued_operations, [])
  @doc false
  def reinstate(state) do
    state
    |> Map.put(:queued_operations, [])
    |> restore_pending_tasks()
    |> fail_interrupted_tasks()
  end

  defp restore_pending_tasks(state) do
    tasks =
      state
      |> Map.get(:pending_tasks, %{})
      |> Map.new(fn {id, data} -> {id, pending_task_record(id, data)} end)

    %{state | tasks: Map.merge(state.tasks, tasks)}
  end

  defp pending_task_record(id, data) do
    %{
      id: id,
      member: data.member,
      status: :dispatched,
      result: nil,
      attempt: nil,
      notify: data[:notify],
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
