defmodule Aikido.AgentServer.RuntimeActions do
  @moduledoc "Built-in native Ash actions available to every agent runtime."
  use Ash.Resource, domain: Aikido.RuntimeDomain, data_layer: Ash.DataLayer.Simple

  actions do
    action :query_children, Aikido.ActionResult do
      description "Reply with the agent's child process identifiers."
      run Aikido.AgentServer.Actions.QueryChildren
    end

    action :cancel, Aikido.ActionResult do
      argument :state, :term
      argument :reason, :term, description: "Cancellation reason", default: :cancelled
      description "Handle cancellation requests"
      run Aikido.Actions.Control.Cancel
    end

    action :noop, Aikido.ActionResult do
      argument :state, :term
      description "No-operation, acknowledges signal without changes"
      run Aikido.Actions.Control.Noop
    end

    action :forward, Aikido.ActionResult do
      argument :state, :term
      argument :target_pid, :term, description: "Target process PID", allow_nil?: false
      argument :signal_type, :string, description: "New signal type (optional)", default: nil
      argument :payload, :map, description: "New payload (optional)", default: nil
      argument :source, :string, description: "New source (optional)", default: nil
      description "Forward a signal to another agent"
      run Aikido.Actions.Control.Forward
    end

    action :broadcast, Aikido.ActionResult do
      argument :state, :term
      argument :topic, :string, description: "PubSub topic", allow_nil?: false
      argument :signal_type, :string, description: "Signal type to broadcast", allow_nil?: false
      argument :payload, :map, description: "Signal payload", default: %{}
      argument :source, :string, description: "Signal source", default: "/broadcast"
      description "Broadcast a signal via PubSub"
      run Aikido.Actions.Control.Broadcast
    end

    action :reply, Aikido.ActionResult do
      argument :state, :term
      argument :signal_type, :string, description: "Reply signal type", allow_nil?: false
      argument :payload, :map, description: "Reply payload", default: %{}
      description "Reply to the signal source"
      run Aikido.Actions.Control.Reply
    end

    action :notify_parent, Aikido.ActionResult do
      argument :state, :term

      argument :signal_type, :string,
        description: "Signal type to emit to parent",
        allow_nil?: false

      argument :payload, :map, description: "Signal payload data", default: %{}
      argument :source, :string, description: "Signal source path", default: "/child"
      description "Emit a signal back to the parent agent"
      run Aikido.Actions.Lifecycle.NotifyParent
    end

    action :notify_pid, Aikido.ActionResult do
      argument :state, :term
      argument :target_pid, :term, description: "Target process PID", allow_nil?: false
      argument :signal_type, :string, description: "Signal type to emit", allow_nil?: false
      argument :payload, :map, description: "Signal payload data", default: %{}
      argument :source, :string, description: "Signal source path", default: "/agent"

      argument :delivery_mode, :atom,
        description: "Delivery mode",
        default: :async,
        constraints: [one_of: [:async, :sync]]

      description "Emit a signal to a specific process"
      run Aikido.Actions.Lifecycle.NotifyPid
    end

    action :spawn_child, Aikido.ActionResult do
      argument :state, :term
      argument :agent_module, :atom, description: "Agent module to spawn", allow_nil?: false
      argument :tag, :atom, description: "Tag for tracking this child", allow_nil?: false
      argument :initial_state, :map, description: "Initial state for child", default: %{}
      argument :meta, :map, description: "Metadata to pass to child", default: %{}

      argument :restart, :atom,
        description: "Restart policy for the child",
        default: :transient,
        constraints: [one_of: Aikido.Directives.valid_restart_policies()]

      description "Spawn a child agent with hierarchy tracking"
      run Aikido.Actions.Lifecycle.SpawnChild
    end

    action :stop_self, Aikido.ActionResult do
      argument :state, :term
      argument :reason, :term, description: "Reason for stopping", default: :normal
      description "Request graceful termination of this agent"
      run Aikido.Actions.Lifecycle.StopSelf
    end

    action :stop_child, Aikido.ActionResult do
      argument :state, :term
      argument :tag, :atom, description: "Tag of child to stop", allow_nil?: false
      argument :reason, :term, description: "Reason for stopping", default: :normal
      description "Request graceful termination of a child agent"
      run Aikido.Actions.Lifecycle.StopChild
    end

    action :schedule_signal, Aikido.ActionResult do
      argument :state, :term

      argument :delay_ms, :integer,
        description: "Delay in milliseconds",
        allow_nil?: false,
        constraints: [min: 0]

      argument :signal_type, :string, description: "Signal type to schedule", allow_nil?: false
      argument :payload, :map, description: "Signal payload data", default: %{}
      argument :source, :string, description: "Signal source path", default: "/scheduler"
      description "Schedule a signal to be delivered after a delay"
      run Aikido.Actions.Scheduling.ScheduleSignal
    end

    action :schedule_timeout, Aikido.ActionResult do
      argument :state, :term

      argument :timeout_ms, :integer,
        description: "Timeout in milliseconds",
        allow_nil?: false,
        constraints: [min: 0]

      argument :timeout_id, :term, description: "Identifier for this timeout", default: :default

      argument :signal_type, :string,
        description: "Timeout signal type",
        default: "agent.timeout"

      description "Schedule a timeout signal for deadline handling"
      run Aikido.Actions.Scheduling.ScheduleTimeout
    end

    action :schedule_cron, Aikido.ActionResult do
      argument :state, :term
      argument :cron, :string, description: "Cron expression", allow_nil?: false
      argument :job_id, :term, description: "Job identifier for cancellation", default: nil
      argument :signal_type, :string, description: "Signal type to schedule", allow_nil?: false
      argument :payload, :map, description: "Signal payload data", default: %{}
      argument :timezone, :string, description: "Timezone for cron evaluation", default: nil
      description "Schedule a recurring signal using cron expression"
      run Aikido.Actions.Scheduling.ScheduleCron
    end

    action :cancel_cron, Aikido.ActionResult do
      argument :state, :term
      argument :job_id, :term, description: "Job identifier to cancel", allow_nil?: false
      description "Cancel a scheduled cron job"
      run Aikido.Actions.Scheduling.CancelCron
    end
  end
end
