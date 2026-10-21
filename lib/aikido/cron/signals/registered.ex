defmodule Aikido.Cron.Signals.Registered do
  @moduledoc """
  Synthesized by the `Aikido.Cron.Directives.Register` impl after the
  scheduler job spawns, then cast back to the
  agent so the cascade callback `maybe_track_cron_registered/2` can
  insert into `state.cron_specs`, `state.cron_jobs`, `state.cron_monitors`,
  `state.cron_monitor_refs`, and `state.cron_runtime_specs`.

  Directives mutate no state. The directive does the I/O (start the
  scheduler job + `Process.monitor`); the cascade
  callback observes this synthetic signal and writes the runtime maps.
  Subscribers can also observe the registration. DurableServer snapshots the
  resulting logical specs at the callback synchronization boundary.

  ## Fields

  - `:job_id` - Logical cron job id within the agent
  - `:pid` - PID of the spawned cron-job process
  - `:monitor_ref` - Monitor reference returned by `Process.monitor/1`
  - `:cron_spec` - The validated `%{cron_expression, message, timezone}` spec
  - `:runtime_spec` - The `%Aikido.Cron.RuntimeSpec{}` carrying scheduler details
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.cron.registered"

    schema do
      attribute :job_id, :term do
        allow_nil? false
        description "Logical cron job id within the agent"
      end

      attribute :pid, :term do
        allow_nil? false
        description "PID of the spawned cron-job process"
      end

      attribute :monitor_ref, :term do
        allow_nil? false
        description "Monitor reference for the cron-job process"
      end

      attribute :cron_spec, :term do
        allow_nil? false
        description "Validated cron spec map"
      end

      attribute :runtime_spec, :term do
        allow_nil? false
        description "%Aikido.Cron.RuntimeSpec{} carrying scheduler details"
      end
    end
  end
end
