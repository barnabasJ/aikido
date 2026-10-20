defmodule AikidoTest.Integration.SchedulerIntegrationTest.SliceTickAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    count = Map.get(slice, :tick_count, 0)
    ticks = Map.get(slice, :ticks, [])

    Aikido.Types.ActionResult.new(
      state: %{tick_count: count + 1, ticks: ticks ++ [%{source: :slice_schedule}]},
      directives: []
    )
  end
end

defmodule AikidoTest.Integration.SchedulerIntegrationTest.ScheduledSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "scheduler_integration_slice"

    schema do
      attribute :tick_count, :integer, default: 0
      attribute :ticks, {:array, :term}, default: []
    end
  end

  schedules do
    schedule "* * * * * * *",
             {AikidoTest.Integration.SchedulerIntegrationTest.ScheduledSlice, :slice_tick}
  end

  actions do
    action :slice_tick, Aikido.Types.ActionResult do
      argument :state, :term

      run AikidoTest.Integration.SchedulerIntegrationTest.SliceTickAction.Implementation
    end
  end
end

defmodule AikidoTest.Integration.SchedulerIntegrationTest.SliceScheduledAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "scheduler_integration_slice_agent"
    path :domain

    schema do
      attribute :tick_count, :integer, default: 0
      attribute :ticks, {:array, :term}, default: []
    end

    slice :scheduler_integration_slice,
          AikidoTest.Integration.SchedulerIntegrationTest.ScheduledSlice
  end
end

defmodule AikidoTest.Integration.SchedulerIntegrationTest do
  @moduledoc """
  Scheduler integration tests for invasive runtime failure scenarios.

  Run this subset with:

      mix test --only scheduler_integration test/aikido/integration/scheduler_integration_test.exs
  """
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog
  import AikidoTest.Support.SchedulerIntegrationHarness
  @moduletag :integration
  @moduletag :scheduler_integration
  @moduletag capture_log: true
  @moduletag timeout: 20_000

  defp slice_job_id do
    [spec] =
      Aikido.Dsl.Agent.Info.schedules(
        AikidoTest.Integration.SchedulerIntegrationTest.SliceScheduledAgent
      )

    spec.job_id
  end

  describe("runtime scheduler failures") do
    test(
      "cron job enters retry mode during time zone database failure and resumes after recovery",
      context
    ) do
      on_exit(fn ->
        Application.put_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
      end)

      pid = start_cron_agent(context, id: unique_id("scheduler-retry"))

      assert :ok =
               register_cron(pid, "* * * * * * *",
                 job_id: :heartbeat,
                 timezone: "America/New_York"
               )

      job_pid = wait_for_job(pid, :heartbeat, timeout: 5000)
      wait_for_tick_count(pid, 1, timeout: 5000)
      server_ref = Process.monitor(pid)

      :persistent_term.put({AikidoTest.Support.FailingTimeZoneDatabase, :observer}, self())

      on_exit(fn ->
        :persistent_term.erase({AikidoTest.Support.FailingTimeZoneDatabase, :observer})
      end)

      Application.put_env(
        :aikido,
        :time_zone_database,
        AikidoTest.Support.FailingTimeZoneDatabase
      )

      assert Process.alive?(pid)

      assert_receive {:time_zone_resolution_failed, ^job_pid}, 5000
      job_state = :sys.get_state(job_pid)
      assert job_state.retrying?

      # A tick still dispatches its callback when rescheduling fails.
      for {_ref, worker} <- job_state.callback_workers do
        AikidoTest.LifecycleWait.await_down(worker)
      end

      {:ok, %{heartbeat_pid: heartbeat_pid, baseline: baseline}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok,
           %{heartbeat_pid: s.cron_jobs[:heartbeat], baseline: s.agent.state.domain.tick_count}}
        end)

      assert heartbeat_pid == job_pid
      assert Process.alive?(job_pid)
      Application.put_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)

      wait_for_tick_count(pid, baseline + 1, timeout: 8000)
      refute :sys.get_state(job_pid).retrying?
      refute_received {:DOWN, ^server_ref, :process, ^pid, _reason}
    end

    test(
      "non-durable cron payload is isolated and later cron registrations still work",
      context
    ) do
      pid = start_cron_agent(context, id: unique_id("scheduler-bad-message"))
      server_ref = Process.monitor(pid)

      bad_message =
        Aikido.Signal.new!("cron.tick", %{reply_to: self(), kind: :bad_message}, source: "/test")

      good_message = Aikido.Signal.new!("cron.tick", %{kind: :good_message}, source: "/test")

      log =
        capture_log(fn ->
          assert :ok =
                   register_cron(pid, "* * * * * * *", job_id: :bad_message, message: bad_message)

          assert :ok =
                   register_cron(pid, "* * * * * * *",
                     job_id: :good_message,
                     message: good_message
                   )

          good_job_pid = wait_for_job(pid, :good_message, timeout: 5000)
          assert Process.alive?(good_job_pid)

          await_state_value(
            pid,
            fn s ->
              ticks = s.agent.state.domain.ticks
              count = Enum.count(ticks, &(&1[:kind] == :good_message))

              if count >= 1 do
                count
              end
            end,
            timeout: 5000
          )
        end)

      {:ok, snapshot} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.cron_jobs, cron_specs_keys: Map.keys(s.cron_specs)}}
        end)

      refute Map.has_key?(snapshot.cron_jobs, :bad_message)
      refute :bad_message in snapshot.cron_specs_keys
      assert is_pid(snapshot.cron_jobs[:good_message])
      assert Process.alive?(snapshot.cron_jobs[:good_message])
      refute_received {:DOWN, ^server_ref, :process, ^pid, _reason}
      assert log =~ "failed to register cron job :bad_message"
    end

    test("restarting one dynamic cron job does not disrupt sibling jobs", context) do
      pid = start_cron_agent(context, id: unique_id("scheduler-siblings"))
      server_ref = Process.monitor(pid)
      alpha_message = Aikido.Signal.new!("cron.tick", %{job: :alpha}, source: "/test")
      beta_message = Aikido.Signal.new!("cron.tick", %{job: :beta}, source: "/test")
      assert :ok = register_cron(pid, "* * * * * * *", job_id: :alpha, message: alpha_message)
      assert :ok = register_cron(pid, "* * * * * * *", job_id: :beta, message: beta_message)
      alpha_job_pid = wait_for_job(pid, :alpha, timeout: 5000)
      beta_job_pid = wait_for_job(pid, :beta, timeout: 5000)

      await_state_value(
        pid,
        fn s ->
          ticks = s.agent.state.domain.ticks

          if Enum.any?(ticks, &(&1[:job] == :alpha)) and Enum.any?(ticks, &(&1[:job] == :beta)) do
            true
          end
        end,
        timeout: 5000
      )

      beta_baseline = ticks(pid) |> Enum.count(&(&1[:job] == :beta))
      Process.exit(alpha_job_pid, :kill)

      restarted_alpha_pid =
        await_state_value(
          pid,
          fn s ->
            new_alpha_pid = s.cron_jobs[:alpha]

            if is_pid(new_alpha_pid) and new_alpha_pid != alpha_job_pid and
                 Process.alive?(new_alpha_pid) do
              new_alpha_pid
            end
          end,
          timeout: 6000
        )

      assert Process.alive?(beta_job_pid)
      {:ok, beta_pid} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs[:beta]} end)
      assert beta_pid == beta_job_pid
      assert Process.alive?(restarted_alpha_pid)

      await_state_value(
        pid,
        fn s ->
          count = Enum.count(s.agent.state.domain.ticks, &(&1[:job] == :beta))

          if count >= beta_baseline + 1 do
            count
          end
        end,
        timeout: 5000
      )

      refute_received {:DOWN, ^server_ref, :process, ^pid, _reason}
    end
  end

  describe("declarative schedule behavior") do
    test("agent schedules are runtime-only and do not populate durable cron_specs", context) do
      pid = start_scheduled_agent(context, id: unique_id("scheduler-declarative"))
      job_id = scheduled_job_id()
      job_pid = wait_for_job(pid, job_id, timeout: 5000)
      assert Process.alive?(job_pid)
      wait_for_tick_count(pid, 1, timeout: 5000)

      {:ok, snapshot} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{job_pid: s.cron_jobs[job_id], cron_specs: s.cron_specs}}
        end)

      assert snapshot.job_pid == job_pid
      assert snapshot.cron_specs == %{}
    end

    test("agent schedules restart after abnormal scheduler death", context) do
      pid = start_scheduled_agent(context, id: unique_id("scheduler-declarative-restart"))
      job_id = scheduled_job_id()
      original_job_pid = wait_for_job(pid, job_id, timeout: 5000)
      assert Process.alive?(original_job_pid)
      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_job_pid = s.cron_jobs[job_id]

            if is_pid(new_job_pid) and new_job_pid != original_job_pid and
                 Process.alive?(new_job_pid) do
              new_job_pid
            end
          end,
          timeout: 6000
        )

      assert is_pid(restarted_job_pid)
      assert Process.alive?(restarted_job_pid)
    end
  end

  describe("slice schedule behavior") do
    test("slice schedules are runtime-only and deliver ticks", context) do
      pid =
        start_server(context, AikidoTest.Integration.SchedulerIntegrationTest.SliceScheduledAgent,
          id: unique_id("scheduler-slice-runtime")
        )

      job_id = slice_job_id()
      job_pid = wait_for_job(pid, job_id, timeout: 5000)
      assert Process.alive?(job_pid)

      AikidoTest.AgentWait.await_state_value(
        pid,
        fn state ->
          slice = state.agent.state.scheduler_integration_slice

          if slice.tick_count >= 1 and Enum.any?(slice.ticks, &(&1[:source] == :slice_schedule)),
            do: true
        end,
        timeout: 5000
      )

      {:ok, snapshot} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{job_pid: s.cron_jobs[job_id], cron_specs: s.cron_specs}}
        end)

      assert snapshot.job_pid == job_pid
      assert snapshot.cron_specs == %{}
    end

    test("slice schedules restart after abnormal scheduler death", context) do
      pid =
        start_server(context, AikidoTest.Integration.SchedulerIntegrationTest.SliceScheduledAgent,
          id: unique_id("scheduler-slice-restart")
        )

      job_id = slice_job_id()
      original_job_pid = wait_for_job(pid, job_id, timeout: 5000)
      assert Process.alive?(original_job_pid)
      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_job_pid = s.cron_jobs[job_id]

            if is_pid(new_job_pid) and new_job_pid != original_job_pid and
                 Process.alive?(new_job_pid) do
              new_job_pid
            end
          end,
          timeout: 6000
        )

      assert is_pid(restarted_job_pid)
      assert Process.alive?(restarted_job_pid)
    end
  end
end
