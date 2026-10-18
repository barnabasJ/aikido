defmodule AikidoTest.Support.SchedulerIntegrationHarness do
  @moduledoc false
  alias Aikido.AgentServer
  alias Aikido.Directives
  alias Aikido.Scheduler
  alias Jido.Signal

  defmodule TickAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "cron_count"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      count = Map.get(slice, :tick_count, 0)
      ticks = Map.get(slice, :ticks, [])
      {:ok, %{tick_count: count + 1, ticks: ticks ++ [params]}, []}
    end
  end

  defmodule RegisterCronAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "register_cron"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      cron_expr = Map.get(params, :cron)
      job_id = Map.get(params, :job_id)
      timezone = Map.get(params, :timezone)
      message = Map.get(params, :message, Signal.new!(%{type: "cron.tick", source: "/test"}))
      directive = Directives.cron(cron_expr, message, job_id: job_id, timezone: timezone)
      {:ok, slice, [directive]}
    end
  end

  defmodule CancelCronAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "cancel_cron"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: %{job_id: job_id}}, slice, _opts, _ctx) do
      {:ok, slice, [Directives.cron_cancel(job_id)]}
    end
  end

  defmodule CronAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("scheduler_integration_agent")
      path(:domain)

      schema do
        attribute(:tick_count, :integer, default: 0)
        attribute(:ticks, {:array, :term}, default: [])
      end
    end

    signal_routes do
      route("register_cron", RegisterCronAction)
      route("cancel_cron", CancelCronAction)
      route("cron.tick", TickAction)
    end
  end

  defmodule ScheduledCronAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("scheduler_integration_scheduled_agent")
      path(:domain)

      schema do
        attribute(:tick_count, :integer, default: 0)
        attribute(:ticks, {:array, :term}, default: [])
      end
    end

    schedules do
      schedule("* * * * * * *", "cron.tick", job_id: :scheduled_heartbeat)
    end

    signal_routes do
      route("cron.tick", TickAction)
    end
  end

  def start_cron_agent(context, opts \\ []) do
    AikidoTest.Case.start_server(
      context,
      CronAgent,
      Keyword.put_new(opts, :id, AikidoTest.Case.unique_id("scheduler-integration"))
    )
  end

  def start_scheduled_agent(context, opts \\ []) do
    AikidoTest.Case.start_server(
      context,
      ScheduledCronAgent,
      Keyword.put_new(opts, :id, AikidoTest.Case.unique_id("scheduler-scheduled"))
    )
  end

  def scheduled_job_id do
    {:agent_schedule, "scheduler_integration_scheduled_agent", :scheduled_heartbeat}
  end

  def unique_table(prefix \\ "scheduler_integration") do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  def cleanup_storage_tables(table) do
    Enum.each([:"#{table}_checkpoints", :"#{table}_threads", :"#{table}_thread_meta"], fn t ->
      try do
        :ets.delete(t)
      rescue
        _ -> :ok
      end
    end)
  end

  def checkpoint_key(agent_module, manager, key) do
    {agent_module, {manager, key}}
  end

  def stage_cron_specs(agent, cron_specs) when is_map(cron_specs) do
    Scheduler.attach_staged_cron_specs(agent, cron_specs)
  end

  def register_cron(pid, cron_expr, opts \\ []) do
    message = Keyword.get(opts, :message, Signal.new!(%{type: "cron.tick", source: "/test"}))

    signal =
      Signal.new!(%{
        type: "register_cron",
        source: "/test",
        data: %{
          cron: cron_expr,
          job_id: Keyword.get(opts, :job_id),
          timezone: Keyword.get(opts, :timezone),
          message: message
        }
      })

    AgentServer.cast(pid, signal)
  end

  def cancel_cron(pid, job_id) do
    signal = Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: job_id}})
    AgentServer.cast(pid, signal)
  end

  @doc "Wait for `job_id` to be registered (and alive) in `state.cron_jobs`.\n\nSubscribe-based per ADR 0021 — see `AikidoTest.AgentWait.await_state_value/3`.\n"
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

  @doc "Wait for the agent's domain `tick_count` to reach `count`.\n\nSubscribe-based per ADR 0021 — each `cron.tick` triggers a pipeline\nwhose post-state the subscription evaluates. No polling.\n"
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
    {:ok, count} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.tick_count} end)
    count
  end

  def ticks(pid) do
    {:ok, ticks} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.ticks} end)
    ticks
  end
end
