defmodule Aikido.Cron.Slice do
  @moduledoc """
  Owns recurring schedules, active jobs and restart decisions through native actions.

  Agent resources mount this built-in slice at `:cron`. Durable snapshots retain
  dynamic definitions only; scheduler PIDs, monitors, caller scope and retry state
  are rebuilt on activation. Declarative schedules come from the resource DSL.
  """
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

  slice do
    name "cron"

    schema do
      attribute :jobs, :map do
        description "Active scheduler processes keyed by logical job ID."
        default %{}
        allow_nil? false
      end

      attribute :monitors, :map do
        description "Monitor references keyed by logical job ID."
        default %{}
        allow_nil? false
      end

      attribute :specs, :map do
        description "Durable definitions of dynamically registered schedules."
        default %{}
        allow_nil? false
      end

      attribute :runtime_specs, :map do
        description "Transient scheduler definitions retaining caller scope and tracing."
        default %{}
        allow_nil? false
      end

      attribute :restart_attempts, :map do
        description "Consecutive abnormal restart attempts keyed by logical job ID."
        default %{}
        allow_nil? false
      end

      attribute :generations, :map do
        description "Registration generations used to ignore stale retry signals."
        default %{}
        allow_nil? false
      end

      attribute :errors, :map do
        description "Latest registration failures keyed by logical job ID."
        default %{}
        allow_nil? false
      end
    end

    route Aikido.AgentServer.Signals.LifecycleStarting, Aikido.Cron.Actions.Activate,
      public?: false

    route Aikido.AgentServer.Signals.LifecycleStopping, Aikido.Cron.Actions.StopJobs,
      public?: false

    route [Aikido.Cron.Signals.Cancelled, Aikido.Cron.Signals.Restarted],
          Aikido.Cron.Actions.AcknowledgeJobEvent, public?: false

    route Aikido.Cron.Signals.Registered, Aikido.Cron.Actions.RecordRegistration, public?: false
    route Aikido.Cron.Signals.CancelRequested, Aikido.Cron.Actions.CancelJob, public?: false
    route Aikido.Cron.Signals.Died, Aikido.Cron.Actions.HandleJobExit, public?: false
    route Aikido.Cron.Signals.Retry, Aikido.Cron.Actions.RetryJob, public?: false

    route Aikido.Cron.Signals.RegistrationFailed, Aikido.Cron.Actions.RecordFailure,
      public?: false
  end

  @doc false
  def externalize(state),
    do: %{
      state
      | jobs: %{},
        monitors: %{},
        runtime_specs: %{},
        restart_attempts: %{},
        generations: %{},
        errors: %{}
    }

  @doc false
  def reinstate(state), do: externalize(state)
end
