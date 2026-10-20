defmodule AikidoTest.Support.SchedulerIntegrationHarness.TickAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = input.arguments.data

    slice = input.arguments.state
    count = Map.get(slice, :tick_count, 0)
    ticks = Map.get(slice, :ticks, [])

    Aikido.ActionResult.new(
      state: %{tick_count: count + 1, ticks: ticks ++ [params]},
      directives: []
    )
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.RegisterCronAction.Implementation do
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
        struct!(Jido.Signal, id: nil, type: "cron.tick", data: %{}, source: "/test")

    directive = Aikido.Directives.cron(cron_expr, message, job_id: job_id, timezone: timezone)
    Aikido.ActionResult.new(state: slice, directives: [directive])
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.CancelCronAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    job_id = input.arguments.job_id

    slice = input.arguments.state
    Aikido.ActionResult.new(state: slice, directives: [Aikido.Directives.cron_cancel(job_id)])
  end
end

defmodule AikidoTest.Support.SchedulerIntegrationHarness.CronAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "scheduler_integration_agent"
    path :domain

    schema do
      attribute :tick_count, :integer, default: 0
      attribute :ticks, {:array, :term}, default: []
    end

    route "register_cron",
          {AikidoTest.Support.SchedulerIntegrationHarness.CronAgent, :register_cron}

    route "cancel_cron", {AikidoTest.Support.SchedulerIntegrationHarness.CronAgent, :cancel_cron}
    route "cron.tick", {AikidoTest.Support.SchedulerIntegrationHarness.CronAgent, :cron_count}
  end

  actions do
    action :cron_count, Aikido.ActionResult do
      argument :state, :term
      argument :data, :map, default: %{}

      run AikidoTest.Support.SchedulerIntegrationHarness.TickAction.Implementation
    end

    action :register_cron, Aikido.ActionResult do
      argument :state, :term
      argument :cron, :string, allow_nil?: false
      argument :job_id, :term
      argument :timezone, :string
      argument :message, :term

      run AikidoTest.Support.SchedulerIntegrationHarness.RegisterCronAction.Implementation
    end

    action :cancel_cron, Aikido.ActionResult do
      argument :state, :term
      argument :job_id, :term, allow_nil?: false

      run AikidoTest.Support.SchedulerIntegrationHarness.CancelCronAction.Implementation
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
      attribute :tick_count, :integer, default: 0
      attribute :ticks, {:array, :term}, default: []
    end

    route "cron.tick", {AikidoTest.Support.SchedulerIntegrationHarness.CronAgent, :cron_count}
  end

  schedules do
    schedule "* * * * * * *", "cron.tick", job_id: :scheduled_heartbeat
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
        struct!(Jido.Signal, id: nil, type: "cron.tick", source: "/test")
      )

    signal =
      Jido.Signal.new!(%{
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
    signal = Jido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: job_id}})
    Aikido.AgentServer.cast(pid, signal)
  end

  @doc """
  Wait for `job_id` to be registered (and alive) in `state.cron_jobs`.

  Uses subscriptions; see `AikidoTest.AgentWait.await_state_value/3`.
  """
  def wait_for_job(pid, job_id, opts \\ []) do
    AikidoTest.AgentWait.await_state_value(
      pid,
      fn s ->
        case Map.get(s.cron_jobs, job_id) do
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

  def tick_count(pid) do
    {:ok, count} =
      Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.tick_count} end)

    count
  end

  def ticks(pid) do
    {:ok, ticks} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.ticks} end)
    ticks
  end
end
