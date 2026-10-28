defmodule AikidoTest.AgentServer.CronIntegrationTest.Actions.RecordCronTick do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = input.arguments.data

    slice = input.arguments.state
    count = Map.get(slice, :tick_count, 0)
    ticks = Map.get(slice, :ticks, [])

    Aikido.Types.ActionResult.new(
      changes: %{tick_count: count + 1, ticks: ticks ++ [params]},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest.Actions.RegisterCron do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = Map.delete(input.arguments, :state)

    cron_expr = Map.get(params, :cron)
    job_id = Map.get(params, :job_id)

    message =
      Map.get(params, :message) ||
        %Aikido.Signal{id: nil, type: "cron.tick", source: "/test"}

    timezone = Map.get(params, :timezone)
    directive = Aikido.Directives.cron(cron_expr, message, job_id: job_id, timezone: timezone)
    Aikido.Types.ActionResult.new(changes: %{}, directives: [directive])
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest.Actions.CancelCron do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    job_id =
      input.arguments.job_id

    Aikido.Types.ActionResult.new(
      changes: %{},
      directives: [Aikido.Directives.cron_cancel(job_id)]
    )
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest.CronBatch do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    directives =
      Enum.map(input.arguments.operations, fn
        :cancel -> Aikido.Directives.cron_cancel(:ordered)
        cron -> Aikido.Directives.cron(cron, :tick, job_id: :ordered)
      end)

    Aikido.Types.ActionResult.new(directives: directives)
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "cron_test_agent"
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

    route "register_cron",
          {AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, :register_cron}

    route "cancel_cron", {AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, :cancel_cron}
    route "cron.batch", :cron_batch
    route "cron.tick", {AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, :cron_count}
  end

  actions do
    action :cron_batch, Aikido.Types.ActionResult do
      argument :state, :term
      argument :operations, {:array, :term}, allow_nil?: false
      run AikidoTest.AgentServer.CronIntegrationTest.CronBatch
    end

    action :cron_count, Aikido.Types.ActionResult do
      argument :state, :term
      argument :data, :map, allow_nil?: false, default: %{}

      run AikidoTest.AgentServer.CronIntegrationTest.Actions.RecordCronTick
    end

    action :register_cron, Aikido.Types.ActionResult do
      argument :state, :term
      argument :cron, :string, allow_nil?: false
      argument :job_id, :term
      argument :message, :term
      argument :timezone, :string

      run AikidoTest.AgentServer.CronIntegrationTest.Actions.RegisterCron
    end

    action :cancel_cron, Aikido.Types.ActionResult do
      argument :state, :term
      argument :job_id, :term, allow_nil?: false

      run AikidoTest.AgentServer.CronIntegrationTest.Actions.CancelCron
    end
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest do
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :integration
  @moduletag capture_log: true

  test "false cron IDs support replacement and cancellation", context do
    pid = start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)

    register = fn cron ->
      Aikido.AgentServer.call_until(
        pid,
        signal("register_cron", %{job_id: false, cron: cron, signal_type: "cron.tick"}),
        "aikido.agent.cron.registered",
        &{:ok, {&1.agent.state.cron.jobs, &1.agent.state.cron.specs}}
      )
    end

    assert {:ok, {%{false => first}, %{false => %{cron_expression: "@hourly"}}}} =
             register.("@hourly")

    first_monitor = Process.monitor(first)

    assert {:ok, {%{false => replacement}, %{false => %{cron_expression: "@daily"}}}} =
             register.("@daily")

    refute first == replacement

    assert {:ok, {[false], [false]}} =
             Aikido.AgentServer.state(
               pid,
               &{:ok, {Map.keys(&1.agent.state.cron.jobs), Map.keys(&1.agent.state.cron.specs)}}
             )

    assert_receive {:DOWN, ^first_monitor, :process, ^first, _}
    assert Process.alive?(replacement)
    replacement_monitor = Process.monitor(replacement)

    assert {:ok, {%{}, %{}}} =
             Aikido.AgentServer.call_until(
               pid,
               signal("cancel_cron", %{job_id: false}),
               "aikido.agent.cron.cancelled",
               &{:ok, {&1.agent.state.cron.jobs, &1.agent.state.cron.specs}}
             )

    assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, _}
  end

  for replacement? <- [false, true] do
    test "ordered batch cancellation preserves replacement=#{replacement?}", context do
      pid = start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)

      {:ok, registered} =
        Aikido.AgentServer.subscribe(pid, "aikido.agent.cron.registered", fn runtime ->
          {:ok, runtime.agent.state.cron.jobs.ordered}
        end)

      {:ok, cancelled} =
        Aikido.AgentServer.subscribe(
          pid,
          "aikido.agent.cron.cancelled",
          &{:ok, &1.agent.state.cron.jobs},
          once: true
        )

      operations =
        if unquote(replacement?), do: ["@hourly", :cancel, "@daily"], else: ["@hourly", :cancel]

      assert :ok = Aikido.AgentServer.cast(pid, signal("cron.batch", %{operations: operations}))
      assert_receive {:aikido_subscription, ^registered, %{result: {:ok, first}}}
      monitor = Process.monitor(first)
      assert_receive {:aikido_subscription, ^cancelled, _}
      assert_receive {:DOWN, ^monitor, :process, ^first, _}

      if unquote(replacement?) do
        assert_receive {:aikido_subscription, ^registered, %{result: {:ok, replacement}}}
        refute replacement == first
        assert Process.alive?(replacement)

        assert {:ok, {^replacement, "@daily"}} =
                 Aikido.AgentServer.state(
                   pid,
                   &{:ok,
                    {&1.agent.state.cron.jobs.ordered,
                     &1.agent.state.cron.specs.ordered.cron_expression}}
                 )
      else
        assert {:ok, {0, 0, 0, 0}} =
                 Aikido.AgentServer.state(
                   pid,
                   &{:ok,
                    {map_size(&1.agent.state.cron.jobs), map_size(&1.agent.state.cron.specs),
                     map_size(&1.agent.state.cron.monitors),
                     map_size(&1.agent.state.cron.runtime_specs)}}
                 )

        {:ok, id} = Aikido.AgentServer.state(pid, &{:ok, &1.id})
        monitor = Process.monitor(pid)
        assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(context.aikido), pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}

        restored =
          start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, id: id)

        assert :ok = Aikido.AgentServer.await_ready(restored)

        assert {:ok, {%{}, %{}}} =
                 Aikido.AgentServer.state(
                   restored,
                   &{:ok, {&1.agent.state.cron.jobs, &1.agent.state.cron.specs}}
                 )
      end
    end
  end

  test "queued cancellation follows registration even when its command was already waiting",
       context do
    pid = start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)

    {:ok, registered} =
      Aikido.AgentServer.subscribe(
        pid,
        "aikido.agent.cron.registered",
        &{:ok, &1.agent.state.cron.jobs.queued},
        once: true
      )

    {:ok, cancelled} =
      Aikido.AgentServer.subscribe(
        pid,
        "aikido.agent.cron.cancelled",
        &{:ok, &1.agent.state.cron.specs},
        once: true
      )

    :ok = :sys.suspend(pid)

    try do
      :ok =
        Aikido.AgentServer.cast(pid, signal("register_cron", %{job_id: :queued, cron: "@hourly"}))

      :ok = Aikido.AgentServer.cast(pid, signal("cancel_cron", %{job_id: :queued}))
    after
      :sys.resume(pid)
    end

    assert_receive {:aikido_subscription, ^registered, %{result: {:ok, job}}}
    monitor = Process.monitor(job)
    assert_receive {:aikido_subscription, ^cancelled, %{result: {:ok, specs}}}
    refute Map.has_key?(specs, :queued)
    assert_receive {:DOWN, ^monitor, :process, ^job, _}

    assert {:ok, {%{}, %{}}} =
             Aikido.AgentServer.state(
               pid,
               &{:ok, {&1.agent.state.cron.jobs, &1.agent.state.cron.specs}}
             )
  end

  test "cancelling a suspended job stays responsive and cannot remove a replacement", context do
    pid = start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)
    first = register_job(pid, :reused)
    first_monitor = Process.monitor(first.pid)
    parent = self()
    # Hold a scheduler callback without changing its state, so even OTP stop
    # must wait. Suspending alone still permits system termination messages.
    blocked =
      Task.async(fn ->
        :sys.replace_state(first.pid, fn state ->
          send(parent, :scheduler_blocked)

          receive do
            :release_scheduler -> state
          end
        end)
      end)

    assert_receive :scheduler_blocked
    on_exit(fn -> send(first.pid, :release_scheduler) end)

    {:ok, cancelled} =
      Aikido.AgentServer.subscribe(
        pid,
        "aikido.agent.cron.cancelled",
        &{:ok, &1.agent.state.cron.jobs},
        once: true
      )

    assert {:ok, _} =
             Aikido.AgentServer.call(
               pid,
               signal("cancel_cron", %{job_id: :reused}),
               &{:ok, Map.has_key?(&1.agent.state.cron.jobs, :reused)}
             )

    assert {:ok, false} =
             Aikido.AgentServer.state(
               pid,
               &{:ok, Map.has_key?(&1.agent.state.cron.jobs, :reused)}
             )

    # The old scheduler is still blocked, but the next native command completes.
    second = register_job(pid, :reused)
    refute first.pid == second.pid
    send(first.pid, :release_scheduler)
    Task.await(blocked)
    assert_receive {:DOWN, ^first_monitor, :process, _, _}
    assert_receive {:aikido_subscription, ^cancelled, %{result: {:ok, %{reused: replacement}}}}
    assert replacement == second.pid
    assert Process.alive?(second.pid)

    assert {:ok, %{reused: ^replacement}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.cron.jobs})
  end

  for command <- [:upsert, :cancel] do
    test "#{command} clears pending restart ownership and ignores an already queued timer",
         context do
      pid = start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)
      first = register_job(pid, :pending)
      parent = self()
      handler = "restart-cleanup-#{System.unique_integer([:positive])}"
      {:ok, agent_id} = Aikido.AgentServer.state(pid, &{:ok, &1.id})

      :telemetry.attach(
        handler,
        [:aikido, :agent_server, :cron, :restart_scheduled],
        fn _, _, metadata, _ ->
          if metadata.agent_id == agent_id, do: send(parent, :restart_scheduled)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      Process.exit(first.pid, :kill)
      assert_receive :restart_scheduled

      {:ok, generation} =
        Aikido.AgentServer.state(
          pid,
          &{:ok, Map.fetch!(&1.agent.state.cron.generations, :pending)}
        )

      replacement =
        case unquote(command) do
          :upsert ->
            register_job(pid, :pending).pid

          :cancel ->
            assert {:ok, _} =
                     Aikido.AgentServer.call(
                       pid,
                       signal("cancel_cron", %{job_id: :pending}),
                       &{:ok, &1.agent.state.cron.jobs}
                     )

            nil
        end

      Aikido.AgentServer.cast(
        pid,
        Aikido.Cron.Signals.Retry.new!(%{job_id: :pending, generation: generation})
      )

      assert {:ok, {^replacement, 0, true}} =
               Aikido.AgentServer.state(
                 pid,
                 &{:ok,
                  {&1.agent.state.cron.jobs[:pending],
                   map_size(&1.agent.state.cron.restart_attempts),
                   &1.agent.state.cron.generations[:pending] > generation}}
               )
    end
  end

  test "duplicate registration of the same incarnation retains one live monitor", context do
    pid = start_server(context, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)
    job = register_job(pid, :duplicate)

    duplicate =
      signal("aikido.agent.cron.registered", %{
        job_id: :duplicate,
        pid: job.pid,
        monitor_ref: job.ref,
        cron_spec: job.spec,
        runtime_spec: job.runtime_spec
      })

    Aikido.AgentServer.cast(pid, duplicate)

    assert {:ok, {true, 1, 1}} =
             Aikido.AgentServer.state(
               pid,
               &{:ok,
                {Process.alive?(job.pid), map_size(&1.agent.state.cron.monitors),
                 map_size(&1.agent.state.cron.jobs)}}
             )
  end

  test "saturated task supervision cannot leave a retired scheduler running", _context do
    instance = __MODULE__.Limited

    start_supervised!(
      {Aikido, name: instance, max_tasks: 1, durable: AikidoTest.Case.durable_options()}
    )

    pid =
      start_server(%{aikido: instance}, AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent)

    job = register_job(pid, :limited)
    monitor = Process.monitor(job.pid)
    parent = self()

    {:ok, blocker} =
      Task.Supervisor.start_child(Aikido.task_supervisor_name(instance), fn ->
        send(parent, :task_slot_taken)

        receive do
          :release -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(blocker), do: send(blocker, :release) end)
    assert_receive :task_slot_taken
    replacement = register_job(pid, :limited)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert Process.alive?(replacement.pid)
    replacement_monitor = Process.monitor(replacement.pid)

    assert {:ok, _} =
             Aikido.AgentServer.call(
               pid,
               signal("cancel_cron", %{job_id: :limited}),
               &{:ok, Map.has_key?(&1.agent.state.cron.jobs, :limited)}
             )

    assert_receive {:DOWN, ^replacement_monitor, :process, _, :killed}

    assert {:ok, {0, 0}} =
             Aikido.AgentServer.state(
               pid,
               &{:ok,
                {map_size(&1.agent.state.cron.runtime_specs), map_size(&1.agent.state.cron.specs)}}
             )

    send(blocker, :release)
  end

  defp register_job(pid, name) do
    {:ok, job} =
      Aikido.AgentServer.call_until(
        pid,
        signal("register_cron", %{job_id: name, cron: "@hourly"}),
        "aikido.agent.cron.registered",
        fn runtime ->
          {:ok,
           %{
             pid: runtime.agent.state.cron.jobs[name],
             ref: runtime.agent.state.cron.monitors[name],
             spec: runtime.agent.state.cron.specs[name],
             runtime_spec: runtime.agent.state.cron.runtime_specs[name]
           }}
        end
      )

    job
  end

  describe("cron job registration") do
    test("agent can register a cron job", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-1"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :heartbeat, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :heartbeat) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)
      GenServer.stop(pid)
    end

    test("agent can register multiple cron jobs", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-2"
        )

      for {job_id, cron_expr} <- [heartbeat: "* * * * *", daily: "@daily", hourly: "@hourly"] do
        register_signal =
          Aikido.Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: job_id, cron: cron_expr}
          })

        :ok = Aikido.AgentServer.cast(pid, register_signal)
      end

      cron_jobs =
        await_state_value(pid, fn s ->
          if map_size(s.agent.state.cron.jobs) == 3 do
            s.agent.state.cron.jobs
          end
        end)

      assert Map.has_key?(cron_jobs, :heartbeat)
      assert Map.has_key?(cron_jobs, :daily)
      assert Map.has_key?(cron_jobs, :hourly)

      for {_id, job_pid} <- cron_jobs do
        assert is_pid(job_pid)
        assert Process.alive?(job_pid)
      end

      GenServer.stop(pid)
    end

    test("registering same job_id updates existing job (upsert)", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-3"
        )

      register_signal1 =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :updatable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal1)

      first_job_pid =
        await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :updatable) end)

      assert is_pid(first_job_pid)
      first_monitor = Process.monitor(first_job_pid)

      register_signal2 =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :updatable, cron: "@hourly"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal2)

      cron_jobs =
        await_state_value(pid, fn s ->
          if s.agent.state.cron.jobs[:updatable] &&
               s.agent.state.cron.jobs[:updatable] != first_job_pid do
            s.agent.state.cron.jobs
          end
        end)

      assert map_size(cron_jobs) == 1
      second_job_pid = cron_jobs[:updatable]
      assert is_pid(second_job_pid)
      refute first_job_pid == second_job_pid
      assert_receive {:DOWN, ^first_monitor, :process, ^first_job_pid, _}
      assert Process.alive?(second_job_pid)
      second_monitor = Process.monitor(second_job_pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^second_monitor, :process, ^second_job_pid, _}
    end

    test("failed upsert preserves the existing runtime job and durable spec", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-upsert-invalid"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :stable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      %{job_pid: job_pid, cron_spec: cron_spec} =
        await_state_value(pid, fn s ->
          if Map.has_key?(s.agent.state.cron.jobs, :stable) and
               Map.has_key?(s.agent.state.cron.specs, :stable) do
            %{
              job_pid: s.agent.state.cron.jobs[:stable],
              cron_spec: s.agent.state.cron.specs[:stable]
            }
          end
        end)

      invalid_update_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :stable, cron: "not-a-cron"}
        })

      :ok = Aikido.AgentServer.cast(pid, invalid_update_signal)

      cron_spec_after =
        await_state_value(pid, fn s ->
          if s.agent.state.cron.jobs[:stable] == job_pid and
               s.agent.state.cron.specs[:stable] == cron_spec do
            s.agent.state.cron.specs[:stable]
          end
        end)

      assert Process.alive?(job_pid)
      assert cron_spec_after.cron_expression == "* * * * *"
      GenServer.stop(pid)
    end

    test("invalid dynamic cron input is rejected and preserves the agent", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-invalid-type"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_type, cron: 123}
        })

      assert {:error, %Ash.Error.Invalid{}} =
               Aikido.AgentServer.call(pid, register_signal, fn s -> {:ok, s.agent} end)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.agent.state.cron.jobs, cron_specs: s.agent.state.cron.specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_type)
      refute Map.has_key?(cron_specs, :invalid_type)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("rejects non-durable cron messages during registration", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-invalid-message"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_message, cron: "* * * * *", message: {:notify, self()}}
        })

      log =
        capture_log(fn ->
          assert {:ok, _agent} =
                   Aikido.AgentServer.call(pid, register_signal, fn s -> {:ok, s.agent} end)

          {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
            Aikido.AgentServer.state(pid, fn s ->
              {:ok, %{cron_jobs: s.agent.state.cron.jobs, cron_specs: s.agent.state.cron.specs}}
            end)

          refute Map.has_key?(cron_jobs, :invalid_message)
          refute Map.has_key?(cron_specs, :invalid_message)
        end)

      assert log =~ "invalid_message"
      GenServer.stop(pid)
    end

    test("cron job with timezone", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-4"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :timezone_test, cron: "0 9 * * *", timezone: "Etc/UTC"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      job_pid =
        await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :timezone_test) end)

      assert is_pid(job_pid)
      GenServer.stop(pid)
    end

    test("invalid cron directive is isolated and agent survives", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-4b"
        )

      ref = Process.monitor(pid)

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_cron, cron: "definitely-not-a-cron"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      assert Process.alive?(pid)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.agent.state.cron.jobs, cron_specs: s.agent.state.cron.specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_cron)
      refute Map.has_key?(cron_specs, :invalid_cron)
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test("invalid timezone directive is isolated and agent survives", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-4c"
        )

      ref = Process.monitor(pid)

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_tz, cron: "0 9 * * *", timezone: "Invalid/Nowhere"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      assert Process.alive?(pid)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.agent.state.cron.jobs, cron_specs: s.agent.state.cron.specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_tz)
      refute Map.has_key?(cron_specs, :invalid_tz)
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test("auto-generates job_id if not provided", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-5"
        )

      register_signal =
        Aikido.Signal.new!(%{type: "register_cron", source: "/test", data: %{cron: "* * * * *"}})

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      cron_jobs =
        await_state_value(pid, fn s ->
          if map_size(s.agent.state.cron.jobs) == 1 do
            s.agent.state.cron.jobs
          end
        end)

      [job_id] = Map.keys(cron_jobs)
      assert is_reference(job_id)
      GenServer.stop(pid)
    end
  end

  describe("runtime failure isolation and recovery") do
    test("abnormal cron job death does not kill agent and job restarts", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-9a"
        )

      server_ref = Process.monitor(pid)

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :restartable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      original_job_pid =
        await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :restartable) end)

      assert is_pid(original_job_pid)
      assert Process.alive?(original_job_pid)
      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_pid = Map.get(s.agent.state.cron.jobs, :restartable)

            if is_pid(new_pid) and new_pid != original_job_pid and Process.alive?(new_pid) do
              new_pid
            end
          end,
          timeout: 6000
        )

      refute restarted_job_pid == original_job_pid
      assert Process.alive?(pid)
      refute_received {:DOWN, ^server_ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test("cancel removes durable spec even when runtime pid is already gone", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-9b"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :gone_runtime, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      job_pid =
        await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :gone_runtime) end)

      assert is_pid(job_pid)
      Process.exit(job_pid, :shutdown)

      await_state_value(
        pid,
        fn s ->
          if not Map.has_key?(s.agent.state.cron.jobs, :gone_runtime) and
               Map.has_key?(s.agent.state.cron.specs, :gone_runtime) do
            true
          end
        end,
        timeout: 2000
      )

      cancel_signal =
        Aikido.Signal.new!(%{
          type: "cancel_cron",
          source: "/test",
          data: %{job_id: :gone_runtime}
        })

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(
        pid,
        fn s ->
          if not Map.has_key?(s.agent.state.cron.jobs, :gone_runtime) and
               not Map.has_key?(s.agent.state.cron.specs, :gone_runtime) do
            true
          end
        end,
        timeout: 2000
      )

      GenServer.stop(pid)
    end
  end

  describe("cron job cancellation") do
    test("agent can cancel a cron job", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-6"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :cancellable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :cancellable) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)

      cancel_signal =
        Aikido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :cancellable}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if not Map.has_key?(s.agent.state.cron.jobs, :cancellable) do
          true
        end
      end)

      AikidoTest.LifecycleWait.await_down(job_pid)
      GenServer.stop(pid)
    end

    test("cancelling non-existent job is safe", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-7"
        )

      cancel_signal =
        Aikido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :nonexistent}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if map_size(s.agent.state.cron.jobs) == 0 do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("can cancel and re-register same job_id", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-8"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :toggle, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s ->
        if Map.has_key?(s.agent.state.cron.jobs, :toggle) do
          true
        end
      end)

      cancel_signal =
        Aikido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :toggle}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if not Map.has_key?(s.agent.state.cron.jobs, :toggle) do
          true
        end
      end)

      register_signal2 =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :toggle, cron: "@hourly"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal2)
      job_pid = await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :toggle) end)
      assert is_pid(job_pid)
      GenServer.stop(pid)
    end
  end

  describe("cleanup on agent termination") do
    test("cron jobs are cleaned up when agent stops normally", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-10"
        )

      register_signal =
        Aikido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :cleanup_test, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      job_pid =
        await_state_value(pid, fn s -> Map.get(s.agent.state.cron.jobs, :cleanup_test) end)

      assert is_pid(job_pid)
      assert Process.alive?(job_pid)
      GenServer.stop(pid)
      AikidoTest.LifecycleWait.await_down(job_pid)
    end

    test("multiple cron jobs are all cleaned up on termination", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-11"
        )

      job_ids = [:job1, :job2, :job3]

      for job_id <- job_ids do
        register_signal =
          Aikido.Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: job_id, cron: "* * * * *"}
          })

        :ok = Aikido.AgentServer.cast(pid, register_signal)
      end

      cron_jobs =
        await_state_value(pid, fn s ->
          if map_size(s.agent.state.cron.jobs) == 3 do
            s.agent.state.cron.jobs
          end
        end)

      job_pids = Enum.map(job_ids, fn id -> cron_jobs[id] end)

      for job_pid <- job_pids do
        assert is_pid(job_pid)
        assert Process.alive?(job_pid)
      end

      GenServer.stop(pid)

      for job_pid <- job_pids do
        AikidoTest.LifecycleWait.await_down(job_pid)
      end
    end
  end

  describe("job scoping") do
    test("different agents can use same job_id without collision", %{aikido: aikido}) do
      {:ok, pid1} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-12a"
        )

      {:ok, pid2} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-12b"
        )

      for pid <- [pid1, pid2] do
        register_signal =
          Aikido.Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: :shared_name, cron: "* * * * *"}
          })

        :ok = Aikido.AgentServer.cast(pid, register_signal)
      end

      job_pid1 =
        await_state_value(pid1, fn s -> Map.get(s.agent.state.cron.jobs, :shared_name) end)

      job_pid2 =
        await_state_value(pid2, fn s -> Map.get(s.agent.state.cron.jobs, :shared_name) end)

      refute job_pid1 == job_pid2
      assert Process.alive?(job_pid1)
      assert Process.alive?(job_pid2)
      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end
end
