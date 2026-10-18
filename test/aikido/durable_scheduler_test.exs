defmodule AikidoTest.DurableSchedulerTest do
  use AikidoTest.Case, async: false
  import AikidoTest.AgentWait
  alias Aikido.{AgentServer, Durable}
  alias Jido.Signal
  alias AikidoTest.Support.SchedulerIntegrationHarness.{CronAgent, ScheduledCronAgent}

  defp start_pool(aikido, agent) do
    directory =
      Path.join(System.tmp_dir!(), "aikido-durable-cron-#{System.unique_integer([:positive])}")

    pool = AikidoTest.DurableCronPool
    start_supervised!({Durable, name: pool, agent: agent, aikido: aikido, data_dir: directory})
    on_exit(fn -> File.rm_rf!(directory) end)
    pool
  end

  test "native snapshots restore dynamic schedules and retain cancellations", %{aikido: aikido} do
    pool = start_pool(aikido, CronAgent)
    {:ok, first} = Durable.ensure_started(pool, "cron")
    signal = Signal.new!("register_cron", %{job_id: :durable_tick, cron: "* * * * * * *"})
    assert {:ok, _} = AgentServer.call(first, signal, &{:ok, &1.cron_specs})
    old_job = await_state_value(first, &Map.get(&1.cron_jobs, :durable_tick))
    assert :ok = Durable.stop(pool, "cron")
    refute Process.alive?(old_job)
    {:ok, second} = Durable.ensure_started(pool, "cron")
    new_job = await_state_value(second, &Map.get(&1.cron_jobs, :durable_tick))
    refute new_job == old_job
    assert Process.alive?(new_job)

    assert {:ok, _} =
             AgentServer.call(
               second,
               Signal.new!("cancel_cron", %{job_id: :durable_tick}),
               &{:ok, &1.cron_specs}
             )

    assert :ok = Durable.stop(pool, "cron")
    {:ok, third} = Durable.ensure_started(pool, "cron")
    assert :ok = AgentServer.await_ready(third)
    assert {:ok, {%{}, %{}}} = AgentServer.state(third, &{:ok, {&1.cron_jobs, &1.cron_specs}})
  end

  test "declarative schedules rebuild from code without old process handles", %{aikido: aikido} do
    pool = start_pool(aikido, ScheduledCronAgent)
    {:ok, first} = Durable.ensure_started(pool, "declarative")
    assert :ok = AgentServer.await_ready(first)
    assert {:ok, [old_job]} = AgentServer.state(first, &{:ok, Map.values(&1.cron_jobs)})
    assert :ok = Durable.stop(pool, "declarative")
    {:ok, second} = Durable.ensure_started(pool, "declarative")
    assert :ok = AgentServer.await_ready(second)
    assert {:ok, [new_job]} = AgentServer.state(second, &{:ok, Map.values(&1.cron_jobs)})
    refute old_job == new_job
    assert Process.alive?(new_job)
    assert {:ok, %{}} = AgentServer.state(second, &{:ok, &1.cron_specs})
  end
end
