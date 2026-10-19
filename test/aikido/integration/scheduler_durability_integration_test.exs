defmodule AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceTickAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    count = Map.get(slice, :tick_count, 0)
    ticks = Map.get(slice, :ticks, [])

    Aikido.ActionResult.new(
      state: %{tick_count: count + 1, ticks: ticks ++ [%{source: :slice_schedule}]},
      directives: []
    )
  end
end

defmodule AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceTickAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :slice_tick, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceTickAction.Implementation,
           action: :run}
    end
  end
end

defmodule AikidoTest.Integration.SchedulerDurabilityIntegrationTest.ScheduledSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "scheduler_integration_slice"

    schema do
    end
  end

  schedules do
    schedule "* * * * * * *",
             AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceTickAction
  end
end

defmodule AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceScheduledAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "scheduler_integration_slice_agent"
    path :domain

    schema do
      attribute :tick_count, :integer, default: 0
      attribute :ticks, {:array, :term}, default: []
    end
  end

  slices do
    slice :scheduler_integration_slice,
          AikidoTest.Integration.SchedulerDurabilityIntegrationTest.ScheduledSlice
  end
end

defmodule AikidoTest.Integration.SchedulerDurabilityIntegrationTest.RestoreCountingAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "scheduler_restore_counting_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end
  end

  @impl true
  def restore(data, _ctx) do
    case :persistent_term.get({__MODULE__, :notify_pid}, nil) do
      pid when is_pid(pid) -> send(pid, {:restore_called, data.id})
      _ -> :ok
    end

    agent = initialize!(%{id: data.id})
    restored_state = Map.merge(agent.state, Map.get(data, :state, %{}))
    {:ok, %{agent | state: restored_state}}
  end
end

defmodule AikidoTest.Integration.SchedulerDurabilityIntegrationTest do
  @moduledoc """
  Scheduler durability tests that exercise storage-backed hibernate/thaw
  and corrupted replay paths.

  Target only with:

      mix test --only scheduler_integration test/aikido/integration/scheduler_durability_integration_test.exs
  """
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog
  import AikidoTest.Support.SchedulerIntegrationHarness
  @moduletag :integration
  @moduletag :scheduler_integration
  @moduletag capture_log: true
  @moduletag timeout: 25000

  defp slice_job_id do
    {:slice_schedule, :scheduler_integration_slice,
     AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceTickAction}
  end

  defp start_snapshot_fixture(context, agent_module, opts \\ []) do
    manager_name =
      Keyword.get(
        opts,
        :name,
        :"scheduler_integration_manager_#{System.unique_integer([:positive])}"
      )

    table = Keyword.get(opts, :table, unique_table("scheduler_integration_storage"))

    on_exit(fn ->
      cleanup_storage_tables(table)
      Application.put_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
    end)

    manager = %{name: manager_name, agent: agent_module, aikido: context.aikido, table: table}
    %{manager: manager, table: table}
  end

  defp start_persisted_agent(manager, key) do
    Aikido.start_agent(manager.aikido, manager.agent,
      id: key,
      restart: :transient,
      middleware: [
        {Aikido.Middlewares.Persister,
         %{storage: {Aikido.Storage.ETS, table: manager.table}, persistence_key: {manager, key}}}
      ]
    )
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 2000
  end

  describe("storage-backed declarative schedules") do
    test(
      "declarative schedules re-register after explicit shutdown and remain runtime-only",
      context
    ) do
      %{manager: manager} =
        start_snapshot_fixture(
          context,
          AikidoTest.Support.SchedulerIntegrationHarness.ScheduledCronAgent
        )

      instance_key = "declarative-scheduler-1"
      {:ok, pid1} = start_persisted_agent(manager, instance_key)
      job_id = scheduled_job_id()
      job_pid1 = wait_for_job(pid1, job_id, timeout: 5000)
      assert Process.alive?(job_pid1)
      wait_for_tick_count(pid1, 1, timeout: 5000)
      {:ok, cron_specs1} = Aikido.AgentServer.state(pid1, fn s -> {:ok, s.cron_specs} end)
      assert cron_specs1 == %{}
      stop_and_wait(pid1)
      {:ok, pid2} = start_persisted_agent(manager, instance_key)
      job_pid2 = wait_for_job(pid2, job_id, timeout: 5000)
      assert Process.alive?(job_pid2)
      refute job_pid1 == job_pid2
      {:ok, cron_specs2} = Aikido.AgentServer.state(pid2, fn s -> {:ok, s.cron_specs} end)
      assert cron_specs2 == %{}
    end
  end

  describe("corrupted replay cleanup") do
    test("mixed durable replay restores valid spec and drops malformed sibling", context) do
      %{manager: manager, table: table} =
        start_snapshot_fixture(context, AikidoTest.Support.SchedulerIntegrationHarness.CronAgent)

      instance_key = "mixed-replay-1"
      scheduler_key = Aikido.Scheduler.cron_specs_state_key()

      checkpoint_key =
        checkpoint_key(
          AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
          manager,
          instance_key
        )

      good_signal = Jido.Signal.new!("cron.tick", %{kind: :good_replay}, source: "/test")

      checkpoint = %{
        version: 1,
        agent_module: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
        id: instance_key,
        state:
          %{tick_count: 0, ticks: []}
          |> Map.put(scheduler_key, %{
            good: Aikido.Scheduler.build_cron_spec("* * * * * * *", good_signal, "Etc/UTC"),
            broken: %{cron_expression: 123, message: :tick, timezone: "Etc/UTC"}
          }),
        thread: nil
      }

      assert :ok = Aikido.Storage.ETS.put_checkpoint(checkpoint_key, checkpoint, table: table)

      log =
        capture_log(fn ->
          {:ok, pid} = start_persisted_agent(manager, instance_key)
          good_job_pid = wait_for_job(pid, :good, timeout: 5000)
          assert Process.alive?(good_job_pid)

          AikidoTest.AgentWait.await_state_value(
            pid,
            fn state ->
              if Enum.any?(state.agent.state.domain.ticks, &(&1[:kind] == :good_replay)), do: true
            end,
            timeout: 5000
          )

          {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
            Aikido.AgentServer.state(pid, fn s ->
              {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
            end)

          assert Map.has_key?(cron_jobs, :good)
          assert Map.has_key?(cron_specs, :good)
          refute Map.has_key?(cron_jobs, :broken)
          refute Map.has_key?(cron_specs, :broken)
          stop_and_wait(pid)
        end)

      assert log =~ "dropped malformed persisted cron spec"

      assert {:ok, updated_checkpoint} =
               Aikido.Storage.ETS.get_checkpoint(checkpoint_key, table: table)

      persisted_specs = Map.get(updated_checkpoint.state || %{}, scheduler_key, %{})
      assert Map.has_key?(persisted_specs, :good) and not Map.has_key?(persisted_specs, :broken)
    end

    test(
      "malformed persisted cron specs are logged, dropped on thaw, and cleaned on next hibernate",
      context
    ) do
      %{manager: manager, table: table} =
        start_snapshot_fixture(context, AikidoTest.Support.SchedulerIntegrationHarness.CronAgent)

      instance_key = "corrupt-cron-spec-1"
      scheduler_key = Aikido.Scheduler.cron_specs_state_key()

      checkpoint_key =
        checkpoint_key(
          AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
          manager,
          instance_key
        )

      checkpoint = %{
        version: 1,
        agent_module: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
        id: instance_key,
        state:
          %{tick_count: 0, ticks: []}
          |> Map.put(scheduler_key, %{
            broken: %{cron_expression: 123, message: :tick, timezone: "Etc/UTC"}
          }),
        thread: nil
      }

      assert :ok = Aikido.Storage.ETS.put_checkpoint(checkpoint_key, checkpoint, table: table)

      log =
        capture_log(fn ->
          {:ok, pid} = start_persisted_agent(manager, instance_key)

          {:ok, %{cron_specs: cron_specs, cron_jobs: cron_jobs}} =
            Aikido.AgentServer.state(pid, fn s ->
              {:ok, %{cron_specs: s.cron_specs, cron_jobs: s.cron_jobs}}
            end)

          assert cron_specs == %{}
          assert cron_jobs == %{}
          stop_and_wait(pid)
        end)

      assert log =~ "dropped malformed persisted cron spec"

      assert {:ok, updated_checkpoint} =
               Aikido.Storage.ETS.get_checkpoint(checkpoint_key, table: table)

      scheduler_state = Map.get(updated_checkpoint.state || %{}, scheduler_key, %{})
      assert scheduler_state == %{}
    end

    test(
      "replay failure during thaw is scrubbed from persisted state after re-hibernate",
      context
    ) do
      %{manager: manager, table: table} =
        start_snapshot_fixture(context, AikidoTest.Support.SchedulerIntegrationHarness.CronAgent)

      instance_key = "transient-replay-failure-1"
      scheduler_key = Aikido.Scheduler.cron_specs_state_key()

      checkpoint_key =
        checkpoint_key(
          AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
          manager,
          instance_key
        )

      cron_specs = %{
        skipped:
          Aikido.Scheduler.build_cron_spec(
            "* * * * * * *",
            Jido.Signal.new!("cron.tick", %{kind: :replayed}, source: "/test"),
            "America/New_York"
          )
      }

      checkpoint = %{
        version: 1,
        agent_module: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
        id: instance_key,
        state: %{tick_count: 0, ticks: []} |> Map.put(scheduler_key, cron_specs),
        thread: nil
      }

      assert :ok = Aikido.Storage.ETS.put_checkpoint(checkpoint_key, checkpoint, table: table)

      log =
        capture_log(fn ->
          Application.put_env(
            :aikido,
            :time_zone_database,
            AikidoTest.Support.FailingTimeZoneDatabase
          )

          {:ok, pid} = start_persisted_agent(manager, instance_key)

          await_state_value(
            pid,
            fn s ->
              if s.cron_specs == %{} and s.cron_jobs == %{} do
                true
              end
            end,
            timeout: 5000
          )

          Application.put_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
          stop_and_wait(pid)
        end)

      assert log =~ "failed to register cron job :skipped"

      assert {:ok, updated_checkpoint} =
               Aikido.Storage.ETS.get_checkpoint(checkpoint_key, table: table)

      persisted_specs = Map.get(updated_checkpoint.state || %{}, scheduler_key, %{})
      assert persisted_specs == %{}
    end

    test("bad durable replay does not block slice schedules on thaw", context) do
      %{manager: manager, table: table} =
        start_snapshot_fixture(
          context,
          AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceScheduledAgent
        )

      instance_key = "slice-thaw-with-bad-durable-1"
      scheduler_key = Aikido.Scheduler.cron_specs_state_key()

      checkpoint_key =
        checkpoint_key(
          AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceScheduledAgent,
          manager,
          instance_key
        )

      checkpoint = %{
        version: 1,
        agent_module:
          AikidoTest.Integration.SchedulerDurabilityIntegrationTest.SliceScheduledAgent,
        id: instance_key,
        state:
          %{tick_count: 0, ticks: []}
          |> Map.put(scheduler_key, %{
            bad_dynamic: %{cron_expression: 123, message: :tick, timezone: "Etc/UTC"}
          }),
        thread: nil
      }

      assert :ok = Aikido.Storage.ETS.put_checkpoint(checkpoint_key, checkpoint, table: table)

      log =
        capture_log(fn ->
          {:ok, pid} = start_persisted_agent(manager, instance_key)
          slice_pid = wait_for_job(pid, slice_job_id(), timeout: 5000)
          assert Process.alive?(slice_pid)

          AikidoTest.AgentWait.await_state_value(
            pid,
            fn state ->
              domain = state.agent.state.domain

              if domain.tick_count >= 1 and
                   Enum.any?(domain.ticks, &(&1[:source] == :slice_schedule)),
                 do: true
            end,
            timeout: 5000
          )

          {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
            Aikido.AgentServer.state(pid, fn s ->
              {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
            end)

          assert Map.has_key?(cron_jobs, slice_job_id())
          refute Map.has_key?(cron_specs, :bad_dynamic)
          stop_and_wait(pid)
        end)

      assert log =~ "dropped malformed persisted cron spec"
    end

    test("custom restore callback runs exactly once through the starting middleware", context) do
      %{manager: manager, table: table} =
        start_snapshot_fixture(
          context,
          AikidoTest.Integration.SchedulerDurabilityIntegrationTest.RestoreCountingAgent
        )

      instance_key = "restore-once-1"

      :persistent_term.put(
        {AikidoTest.Integration.SchedulerDurabilityIntegrationTest.RestoreCountingAgent,
         :notify_pid},
        self()
      )

      on_exit(fn ->
        :persistent_term.erase(
          {AikidoTest.Integration.SchedulerDurabilityIntegrationTest.RestoreCountingAgent,
           :notify_pid}
        )
      end)

      agent =
        AikidoTest.Integration.SchedulerDurabilityIntegrationTest.RestoreCountingAgent.initialize!(
          %{
            id: "restore-once-agent"
          }
        )

      agent = %{agent | state: %{agent.state | domain: %{agent.state.domain | counter: 41}}}

      assert :ok =
               Aikido.Persist.hibernate(
                 {Aikido.Storage.ETS, table: table},
                 AikidoTest.Integration.SchedulerDurabilityIntegrationTest.RestoreCountingAgent,
                 {manager, instance_key},
                 agent
               )

      {:ok, pid} = start_persisted_agent(manager, instance_key)
      assert_receive {:restore_called, "restore-once-agent"}, 2000
      refute_receive {:restore_called, "restore-once-agent"}, 500

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 41
    end

    test(
      "write-through cron register and cancel do not rewrite corrupt checkpoint state",
      context
    ) do
      %{manager: manager, table: table} =
        start_snapshot_fixture(context, AikidoTest.Support.SchedulerIntegrationHarness.CronAgent)

      register_key = "corrupt-write-through-register"

      register_checkpoint_key =
        checkpoint_key(
          AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
          manager,
          register_key
        )

      register_checkpoint = %{
        version: 1,
        agent_module: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
        id: register_key,
        marker: :register_marker,
        state: [],
        thread: nil
      }

      assert :ok =
               Aikido.Storage.ETS.put_checkpoint(register_checkpoint_key, register_checkpoint,
                 table: table
               )

      {:ok, register_pid} = start_persisted_agent(manager, register_key)
      assert :ok = register_cron(register_pid, "* * * * * * *", job_id: :write_through_register)
      wait_for_job(register_pid, :write_through_register, timeout: 5000)

      assert {:ok, checkpoint} =
               Aikido.Storage.ETS.get_checkpoint(register_checkpoint_key, table: table)

      assert checkpoint.state == [] and checkpoint.marker == :register_marker

      cancel_key = "corrupt-write-through-cancel"

      cancel_checkpoint_key =
        checkpoint_key(
          AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
          manager,
          cancel_key
        )

      {:ok, cancel_pid} = start_persisted_agent(manager, cancel_key)
      assert :ok = register_cron(cancel_pid, "* * * * * * *", job_id: :write_through_cancel)
      wait_for_job(cancel_pid, :write_through_cancel, timeout: 5000)

      corrupt_cancel_checkpoint = %{
        version: 1,
        agent_module: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent,
        id: cancel_key,
        marker: :cancel_marker,
        state: [],
        thread: nil
      }

      assert :ok =
               Aikido.Storage.ETS.put_checkpoint(cancel_checkpoint_key, corrupt_cancel_checkpoint,
                 table: table
               )

      assert :ok = cancel_cron(cancel_pid, :write_through_cancel)

      AikidoTest.AgentWait.await_state_value(cancel_pid, fn state ->
        if not Map.has_key?(state.cron_jobs, :write_through_cancel), do: true
      end)

      assert {:ok, checkpoint} =
               Aikido.Storage.ETS.get_checkpoint(cancel_checkpoint_key, table: table)

      assert checkpoint.state == [] and checkpoint.marker == :cancel_marker
    end
  end
end
