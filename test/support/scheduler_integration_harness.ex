defmodule AikidoTest.Support.SchedulerIntegrationHarness.Signals.RegisterCron do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "register_cron"

    schema do
      attribute :cron, :string do
        description "Cron expression used to schedule delivery."
        allow_nil? false
      end

      attribute :job_id, :term do
        description "Identity of the recurring job."
      end

      attribute :timezone, :string do
        description "Timezone used to interpret the cron expression."
      end

      attribute :message, :term do
        description "Signal delivered when the job fires."
      end
    end
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.Signals.CancelCron do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "cancel_cron"

    schema do
      attribute :job_id, :term do
        description "Identity of the recurring job."
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.Actions.RecordTick do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = input.arguments.data

    slice = input.arguments.state
    count = Map.get(slice, :tick_count, 0)
    ticks = Map.get(slice, :ticks, [])

    Aikido.Types.ActionResult.new(
      state: %{tick_count: count + 1, ticks: ticks ++ [params]},
      directives: []
    )
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.Actions.RegisterCron do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = Map.delete(input.arguments, :state)

    slice = input.arguments.state
    cron_expr = Map.get(params, :cron)
    job_id = Map.get(params, :job_id)
    timezone = Map.get(params, :timezone)

    message =
      Map.get(params, :message) ||
        %Aikido.Signal{id: nil, type: "cron.tick", data: %{}, source: "/test"}

    directive = Aikido.Directives.cron(cron_expr, message, job_id: job_id, timezone: timezone)
    Aikido.Types.ActionResult.new(state: slice, directives: [directive])
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.Actions.CancelCron do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    job_id = input.arguments.job_id

    slice = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: slice,
      directives: [Aikido.Directives.cron_cancel(job_id)]
    )
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.CronAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "scheduler_integration_agent"
    path :domain

    schema do
      attribute :tick_count, :integer do
        description "Number of scheduled ticks handled by the agent."
        default 0
      end

      attribute :ticks, {:array, :term} do
        description "Scheduled tick payloads retained in delivery order."
        default []
      end
    end

    route AikidoTest.Support.SchedulerIntegrationHarness.Signals.RegisterCron,
          AikidoTest.Support.SchedulerIntegrationHarness.Actions.RegisterCron,
          public?: false

    route AikidoTest.Support.SchedulerIntegrationHarness.Signals.CancelCron,
          AikidoTest.Support.SchedulerIntegrationHarness.Actions.CancelCron,
          public?: false

    route "cron.tick", :record_tick, public?: false
  end

  actions do
    action :record_tick, Aikido.Types.ActionResult do
      public? false
      argument :state, :map, allow_nil?: false
      argument :data, :map, default: %{}
      run AikidoTest.Support.SchedulerIntegrationHarness.Actions.RecordTick
    end
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.ScheduledCronAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "scheduler_integration_scheduled_agent"
    path :domain

    schema do
      attribute :tick_count, :integer do
        description "Number of scheduled ticks handled by the agent."
        default 0
      end

      attribute :ticks, {:array, :term} do
        description "Scheduled tick payloads retained in delivery order."
        default []
      end
    end

    route "cron.tick", :record_tick, public?: false
  end

  schedules do
    schedule "* * * * * * *", "cron.tick", job_id: :scheduled_heartbeat
  end

  actions do
    action :record_tick, Aikido.Types.ActionResult do
      public? false
      argument :state, :map, allow_nil?: false
      argument :data, :map, default: %{}
      run AikidoTest.Support.SchedulerIntegrationHarness.Actions.RecordTick
    end
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness do
  @moduledoc false

  def start_cron_agent(context, opts \\ []) do
    AikidoTest.Case.start_server(
      context,
      AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
      Keyword.put_new(opts, :id, AikidoTest.Case.unique_id("scheduler-integration"))
    )
  end

  def start_scheduled_agent(context, opts \\ []) do
    AikidoTest.Case.start_server(
      context,
      AikidoTest.Support.SchedulerIntegrationHarness.ScheduledCronAgent,
      Keyword.put_new(opts, :id, AikidoTest.Case.unique_id("scheduler-scheduled"))
    )
  end

  def scheduled_job_id do
    {:agent_schedule, "scheduler_integration_scheduled_agent", :scheduled_heartbeat}
  end

  def register_cron(pid, cron_expr, opts \\ []) do
    message =
      Keyword.get(
        opts,
        :message,
        %Aikido.Signal{id: nil, type: "cron.tick", source: "/test"}
      )

    signal =
      Aikido.Signal.new!(%{
        type: "register_cron",
        source: "/test",
        data: %{
          cron: cron_expr,
          job_id: Keyword.get(opts, :job_id),
          timezone: Keyword.get(opts, :timezone),
          message: message
        }
      })

    Aikido.AgentServer.cast(pid, signal)
  end

  def cancel_cron(pid, job_id) do
    signal = Aikido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: job_id}})
    Aikido.AgentServer.cast(pid, signal)
  end

  @doc """
  Wait for `job_id` to be registered (and alive) in `state.agent.state.cron.jobs`.

  Uses subscriptions; see `AikidoTest.AgentWait.await_state_value/3`.
  """
  def wait_for_job(pid, job_id, opts \\ []) do
    AikidoTest.AgentWait.await_state_value(
      pid,
      fn s ->
        case Map.get(s.agent.state.cron.jobs, job_id) do
          job_pid when is_pid(job_pid) ->
            if Process.alive?(job_pid) do
              job_pid
            else
              nil
            end

          _ ->
            nil
        end
      end,
      opts
    )
  end

  @doc """
  Wait for the agent's domain `tick_count` to reach `count`.

  Uses subscriptions: each `cron.tick` triggers a pipeline
  whose post-state the subscription evaluates.
  """
  def wait_for_tick_count(pid, count, opts \\ []) do
    AikidoTest.AgentWait.await_state_value(
      pid,
      fn s ->
        tick_count = s.agent.state.domain.tick_count

        if tick_count >= count do
          tick_count
        else
          nil
        end
      end,
      opts
    )
  end

  def ticks(pid) do
    {:ok, ticks} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.ticks} end)
    ticks
  end
end
