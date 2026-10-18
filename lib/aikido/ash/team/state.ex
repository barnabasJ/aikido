defmodule Aikido.Ash.Team.State do
  @moduledoc "Native slice owning team topology, lifecycle progress, tasks, and their actions."
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  attributes do
    attribute :topology, Aikido.Ash.Team.Topology,
      public?: true,
      allow_nil?: false,
      default: %Aikido.Ash.Team.Topology{}

    attribute :members, :map, public?: true, allow_nil?: false, default: %{}
    attribute :incarnations, :map, public?: true, allow_nil?: false, default: %{}
    attribute :paused, :map, public?: true, allow_nil?: false, default: %{}
    attribute :failures, :map, public?: true, allow_nil?: false, default: %{}
    attribute :tasks, :map, public?: true, allow_nil?: false, default: %{}

    attribute :operation, :map,
      public?: true,
      allow_nil?: false,
      default: %{
        id: nil,
        status: :idle,
        remaining: [],
        awaiting: nil,
        started: [],
        stopped: [],
        error: nil
      }
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
    route "aikido.ash.team.exited", :exited
    route "aikido.ash.team.timeout", :timeout
    route "aikido.ash.team.operation.completed", :operation_completed
    route "aikido.ash.team.task.completed", :task_completed
    route "aikido.ash.team.task.failed", :task_failed
    route "aikido.ash.team.task.timeout", :task_timeout
    route "aikido.agent.child.started", :child_started
    route "aikido.agent.child.exit", :child_exit
  end

  actions do
    action :start, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :reconcile, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :add_member, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :remove_member, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :ensure_member, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :stop_member, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :send, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :broadcast, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :assign_task, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :cleanup, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :started, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :stopped, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :failed, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :exited, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :timeout, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :operation_completed, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :task_completed, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :task_failed, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :task_timeout, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :child_started, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end

    action :child_exit, Aikido.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, :map, default: %{}
      run Aikido.Ash.Team.Action
    end
  end
end
