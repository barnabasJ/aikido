defmodule AikidoTest.SchedulerTest.TestModule do
  def test_func(arg) do
    send(arg, :test_func_called)
  end
end

defmodule AikidoTest.SchedulerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    original_database = Calendar.get_time_zone_database()
    on_exit(fn -> Calendar.put_time_zone_database(original_database) end)
    :ok
  end

  defp time_zone_database do
    Application.get_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
  end

  describe("run_every/5 with module/function/args") do
    test "starts a cron job with module, function, and args" do
      assert {:ok, pid} =
               Aikido.Cron.Scheduler.run_every(
                 AikidoTest.SchedulerTest.TestModule,
                 :test_func,
                 [self()],
                 "* * * * *"
               )

      assert is_pid(pid)
      assert Process.alive?(pid)
      Aikido.Cron.Scheduler.cancel(pid)
    end

    test "accepts timezone option" do
      assert {:ok, pid} =
               Aikido.Cron.Scheduler.run_every(
                 AikidoTest.SchedulerTest.TestModule,
                 :test_func,
                 [self()],
                 "* * * * *",
                 timezone: "Etc/UTC"
               )

      assert is_pid(pid)
      Aikido.Cron.Scheduler.cancel(pid)
    end

    test "returns {:error, reason} for invalid cron input" do
      assert {:error, {:invalid_cron, _reason}} =
               Aikido.Cron.Scheduler.run_every(
                 AikidoTest.SchedulerTest.TestModule,
                 :test_func,
                 [self()],
                 "not-a-cron"
               )
    end

    test "returns {:error, reason} for invalid cron type" do
      assert {:error, {:invalid_cron, :invalid_type}} =
               Aikido.Cron.Scheduler.run_every(
                 AikidoTest.SchedulerTest.TestModule,
                 :test_func,
                 [self()],
                 123
               )
    end

    test "returns {:error, reason} for invalid timezone input" do
      assert {:error, {:invalid_timezone, _reason}} =
               Aikido.Cron.Scheduler.run_every(
                 AikidoTest.SchedulerTest.TestModule,
                 :test_func,
                 [self()],
                 "* * * * *",
                 timezone: "Not/A_Zone"
               )
    end

    test "returns {:error, reason} for invalid timezone type" do
      assert {:error, {:invalid_timezone, :invalid_type}} =
               Aikido.Cron.Scheduler.run_every(
                 AikidoTest.SchedulerTest.TestModule,
                 :test_func,
                 [self()],
                 "* * * * *",
                 timezone: 123
               )
    end
  end

  describe("run_every/3 with anonymous function") do
    test "starts a cron job with an anonymous function" do
      test_pid = self()
      fun = fn -> send(test_pid, :anon_func_called) end
      assert {:ok, pid} = Aikido.Cron.Scheduler.run_every(fun, "* * * * *")
      assert is_pid(pid)
      assert Process.alive?(pid)
      Aikido.Cron.Scheduler.cancel(pid)
    end

    test "accepts timezone option" do
      fun = fn -> :ok end
      assert {:ok, pid} = Aikido.Cron.Scheduler.run_every(fun, "* * * * *", timezone: "Etc/UTC")
      assert is_pid(pid)
      Aikido.Cron.Scheduler.cancel(pid)
    end

    test "returns {:error, reason} for invalid cron input without crashing caller" do
      fun = fn -> :ok end

      assert {:error, {:invalid_cron, _reason}} =
               Aikido.Cron.Scheduler.run_every(fun, "not-a-cron-expression")
    end

    test "returns error for invalid timezone identifier without crashing caller" do
      fun = fn -> :ok end

      assert {:error, {:invalid_timezone, _}} =
               Aikido.Cron.Scheduler.run_every(fun, "* * * * *", timezone: "Invalid/Nowhere")
    end

    test "returns error for invalid timezone option type" do
      fun = fn -> :ok end

      assert {:error, {:invalid_timezone, :invalid_type}} =
               Aikido.Cron.Scheduler.run_every(fun, "* * * * *", timezone: :america_chicago)
    end

    test "uses configured time zone database without mutating the global calendar database" do
      Calendar.put_time_zone_database(Calendar.UTCOnlyTimeZoneDatabase)

      assert {:ok, pid} =
               Aikido.Cron.Scheduler.run_every(fn -> :ok end, "* * * * *",
                 timezone: "America/New_York"
               )

      assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
      Aikido.Cron.Scheduler.cancel(pid)
    end

    test "executes callbacks in an isolated worker process" do
      test_pid = self()

      assert {:ok, pid} =
               Aikido.Cron.Scheduler.run_every(
                 fn -> send(test_pid, {:worker_tick, self()}) end,
                 "* * * * * * *"
               )

      assert_receive {:worker_tick, worker_pid}, 2000
      assert is_pid(worker_pid)
      refute worker_pid == pid
      Aikido.Cron.Scheduler.cancel(pid)
    end
  end

  test "forced scheduler death also stops its active callback workers" do
    parent = self()

    {:ok, job} =
      Aikido.Cron.Scheduler.run_every(
        fn ->
          send(parent, {:blocked_callback, self()})

          receive do
            :release -> :ok
          end
        end,
        "@hourly"
      )

    send(job, :tick)
    assert_receive {:blocked_callback, worker}
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    job_ref = Process.monitor(job)
    worker_ref = Process.monitor(worker)
    Process.exit(job, :kill)
    assert_receive {:DOWN, ^job_ref, :process, ^job, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end

  test "a killed callback is removed while the scheduler handles later ticks" do
    parent = self()

    {:ok, job} =
      Aikido.Cron.Scheduler.run_every(
        fn ->
          send(parent, {:blocked_callback, self()})

          receive do
            :release -> :ok
          end
        end,
        "@hourly"
      )

    on_exit(fn -> Aikido.Cron.Scheduler.cancel(job) end)
    send(job, :tick)
    assert_receive {:blocked_callback, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    send(job, :tick)
    assert_receive {:blocked_callback, replacement}
    refute replacement == worker
    refute worker in Map.values(:sys.get_state(job).callback_workers)
    assert Process.alive?(job)
  end

  test "worker EXIT is isolated whether it precedes or queues behind DOWN" do
    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(worker, :stop) end)
    ref = make_ref()
    state = %{callback_workers: %{ref => worker}, owner_ref: nil, owner_pid: nil}

    assert {:noreply, ^state} =
             Aikido.Cron.Job.handle_info({:EXIT, worker, :shutdown}, state)

    send(self(), {:EXIT, worker, :shutdown})

    assert {:noreply, %{callback_workers: workers}} =
             Aikido.Cron.Job.handle_info({:DOWN, ref, :process, worker, :shutdown}, state)

    assert workers == %{}
    refute_receive {:EXIT, ^worker, _}

    assert {:stop, :shutdown, _} =
             Aikido.Cron.Job.handle_info({:EXIT, self(), :shutdown}, %{
               state
               | callback_workers: workers
             })
  end

  describe("cancel/1") do
    test "cancels a running cron job" do
      {:ok, pid} = Aikido.Cron.Scheduler.run_every(fn -> :ok end, "* * * * *")
      assert Process.alive?(pid)
      assert :ok = Aikido.Cron.Scheduler.cancel(pid)
      AikidoTest.LifecycleWait.await_down(pid)
    end

    test "cancels a blocked callback worker and stops future ticks" do
      test_pid = self()

      {:ok, pid} =
        Aikido.Cron.Scheduler.run_every(
          fn ->
            send(test_pid, {:worker_started, self()})
            Process.sleep(:infinity)
          end,
          "* * * * * * *"
        )

      assert_receive {:worker_started, worker_pid}, 2000
      assert is_pid(worker_pid)
      assert :ok = Aikido.Cron.Scheduler.cancel(pid)
      AikidoTest.LifecycleWait.await_down(pid)
      AikidoTest.LifecycleWait.await_down(worker_pid)
      refute_receive {:worker_started, _another_worker}, 1500
    end

    test "callback kill does not take down the owner" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, pid} =
            Aikido.Cron.Scheduler.run_every(
              fn ->
                send(test_pid, {:callback_started, self()})

                receive do
                  :release -> Process.exit(self(), :kill)
                end
              end,
              "* * * * * * *"
            )

          send(test_pid, {:owner_started, self(), pid})

          receive do
            :stop -> Aikido.Cron.Scheduler.cancel(pid)
          end
        end)

      on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)
      ref = Process.monitor(owner)
      assert_receive {:owner_started, ^owner, pid}, 1000
      send(pid, :tick)
      assert_receive {:callback_started, callback}, 2000
      callback_ref = Process.monitor(callback)
      send(callback, :release)
      assert_receive {:DOWN, ^callback_ref, :process, ^callback, :killed}, 2000
      assert is_map(:sys.get_state(pid))
      assert Process.alive?(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 2000
    end
  end

  describe("DST handling") do
    test "skips nonexistent spring-forward occurrences" do
      timezone = "America/Chicago"
      {:ok, schedule} = Aikido.Cron.Job.prepare_schedule("30 2 * * *", timezone)
      {:ok, now} = DateTime.from_naive(~N[2026-03-08 00:30:00], timezone, time_zone_database())

      {:ok, expected} =
        DateTime.from_naive(~N[2026-03-09 02:30:00], timezone, time_zone_database())

      assert {:ok, ^expected} =
               Aikido.Cron.Job.next_scheduled_at(schedule.cron, timezone, now)
    end

    test "chooses the later ambiguous fall-back occurrence" do
      timezone = "America/Chicago"
      {:ok, schedule} = Aikido.Cron.Job.prepare_schedule("31 1 * * *", timezone)

      {:ambiguous, _first_now, now} =
        DateTime.from_naive(~N[2026-11-01 01:30:30], timezone, time_zone_database())

      {:ambiguous, _first_expected, expected} =
        DateTime.from_naive(~N[2026-11-01 01:31:00], timezone, time_zone_database())

      assert {:ok, ^expected} =
               Aikido.Cron.Job.next_scheduled_at(schedule.cron, timezone, now)

      assert DateTime.diff(expected, now, :millisecond) == 30_000
    end
  end

  describe("runtime schedule recovery") do
    test "time zone database failure enters retry mode and resumes without killing the owner" do
      test_pid = self()
      tick_gate = {__MODULE__, make_ref()}
      owner_tag = make_ref()
      :persistent_term.put(tick_gate, false)
      original_database = Application.fetch_env(:aikido, :time_zone_database)
      observer_key = {AikidoTest.Support.FailingTimeZoneDatabase, :observer}
      :persistent_term.put(observer_key, self())
      Application.put_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)

      on_exit(fn ->
        :persistent_term.erase(tick_gate)
        :persistent_term.erase(observer_key)

        case original_database do
          {:ok, database} -> Application.put_env(:aikido, :time_zone_database, database)
          :error -> Application.delete_env(:aikido, :time_zone_database)
        end
      end)

      capture_log(fn ->
        owner =
          spawn(fn ->
            {:ok, pid} =
              Aikido.Cron.Scheduler.run_every(
                fn ->
                  if :persistent_term.get(tick_gate, false) do
                    send(test_pid, {:recovered_tick, owner_tag, self()})
                  end
                end,
                "* * * * * * *",
                timezone: "America/New_York"
              )

            send(test_pid, {:job_started, owner_tag, self(), pid})

            receive do
              :stop -> Aikido.Cron.Scheduler.cancel(pid)
            end
          end)

        on_exit(fn -> send(owner, :stop) end)
        assert_receive {:job_started, ^owner_tag, ^owner, job_pid}, 1000
        assert Process.alive?(owner)
        assert Process.alive?(job_pid)

        Application.put_env(
          :aikido,
          :time_zone_database,
          AikidoTest.Support.FailingTimeZoneDatabase
        )

        send(job_pid, :tick)
        assert_receive {:time_zone_resolution_failed, ^job_pid}, 5_000
        failed_state = :sys.get_state(job_pid)
        assert failed_state.retrying?

        for {_ref, worker} <- failed_state.callback_workers do
          AikidoTest.LifecycleWait.await_down(worker)
        end

        assert Process.alive?(owner)
        assert Process.alive?(job_pid)
        :persistent_term.put(tick_gate, true)
        Application.put_env(:aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
        assert_receive {:recovered_tick, ^owner_tag, worker_pid}, 3000
        assert is_pid(worker_pid)
        refute worker_pid == job_pid
        assert Process.alive?(job_pid)
        refute :sys.get_state(job_pid).retrying?
        send(owner, :stop)
      end)
    end
  end
end
