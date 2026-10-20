defmodule AikidoTest.AgentServer.CronIntegrationTest.CronCountAction.Implementation do
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

defmodule AikidoTest.AgentServer.CronIntegrationTest.RegisterCronAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = Map.delete(input.arguments, :state)

    cron_expr = Map.get(params, :cron)
    job_id = Map.get(params, :job_id)

    message =
      Map.get(params, :message) ||
        struct!(Jido.Signal, id: nil, type: "cron.tick", source: "/test")

    timezone = Map.get(params, :timezone)
    directive = Aikido.Directives.cron(cron_expr, message, job_id: job_id, timezone: timezone)
    Aikido.Types.ActionResult.new(state: %{}, directives: [directive])
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest.CancelCronAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    job_id =
      input.arguments.job_id

    Aikido.Types.ActionResult.new(state: %{}, directives: [Aikido.Directives.cron_cancel(job_id)])
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "cron_test_agent"
    path :domain

    schema do
      attribute :tick_count, :integer, default: 0
      attribute :ticks, {:array, :term}, default: []
    end

    route "register_cron",
          {AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, :register_cron}

    route "cancel_cron", {AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, :cancel_cron}
    route "cron.tick", {AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent, :cron_count}
  end

  actions do
    action :cron_count, Aikido.Types.ActionResult do
      argument :state, :term
      argument :data, :map, allow_nil?: false, default: %{}

      run AikidoTest.AgentServer.CronIntegrationTest.CronCountAction.Implementation
    end

    action :register_cron, Aikido.Types.ActionResult do
      argument :state, :term
      argument :cron, :string, allow_nil?: false
      argument :job_id, :term
      argument :message, :term
      argument :timezone, :string

      run AikidoTest.AgentServer.CronIntegrationTest.RegisterCronAction.Implementation
    end

    action :cancel_cron, Aikido.Types.ActionResult do
      argument :state, :term
      argument :job_id, :term, allow_nil?: false

      run AikidoTest.AgentServer.CronIntegrationTest.CancelCronAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.CronIntegrationTest do
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :integration
  @moduletag capture_log: true

  describe("cron job registration") do
    test("agent can register a cron job", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-1",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :heartbeat, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :heartbeat) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)
      GenServer.stop(pid)
    end

    test("agent can register multiple cron jobs", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-2",
          aikido: aikido
        )

      for {job_id, cron_expr} <- [heartbeat: "* * * * *", daily: "@daily", hourly: "@hourly"] do
        register_signal =
          Jido.Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: job_id, cron: cron_expr}
          })

        :ok = Aikido.AgentServer.cast(pid, register_signal)
      end

      cron_jobs =
        await_state_value(pid, fn s ->
          if map_size(s.cron_jobs) == 3 do
            s.cron_jobs
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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-3",
          aikido: aikido
        )

      register_signal1 =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :updatable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal1)
      first_job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :updatable) end)
      assert is_pid(first_job_pid)

      register_signal2 =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :updatable, cron: "@hourly"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal2)

      cron_jobs =
        await_state_value(pid, fn s ->
          if s.cron_jobs[:updatable] && s.cron_jobs[:updatable] != first_job_pid do
            s.cron_jobs
          end
        end)

      assert map_size(cron_jobs) == 1
      second_job_pid = cron_jobs[:updatable]
      assert is_pid(second_job_pid)
      refute first_job_pid == second_job_pid
      GenServer.stop(pid)
    end

    test("failed upsert preserves the existing runtime job and durable spec", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-upsert-invalid",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :stable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      %{job_pid: job_pid, cron_spec: cron_spec} =
        await_state_value(pid, fn s ->
          if Map.has_key?(s.cron_jobs, :stable) and Map.has_key?(s.cron_specs, :stable) do
            %{job_pid: s.cron_jobs[:stable], cron_spec: s.cron_specs[:stable]}
          end
        end)

      invalid_update_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :stable, cron: "not-a-cron"}
        })

      :ok = Aikido.AgentServer.cast(pid, invalid_update_signal)

      cron_spec_after =
        await_state_value(pid, fn s ->
          if s.cron_jobs[:stable] == job_pid and s.cron_specs[:stable] == cron_spec do
            s.cron_specs[:stable]
          end
        end)

      assert Process.alive?(job_pid)
      assert cron_spec_after.cron_expression == "* * * * *"
      GenServer.stop(pid)
    end

    test("invalid dynamic cron input is rejected and preserves the agent", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-invalid-type",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_type, cron: 123}
        })

      assert {:error, %Ash.Error.Invalid{}} =
               Aikido.AgentServer.call(pid, register_signal, fn s -> {:ok, s.agent} end)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_type)
      refute Map.has_key?(cron_specs, :invalid_type)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("rejects non-durable cron messages during registration", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-invalid-message",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
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
              {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
            end)

          refute Map.has_key?(cron_jobs, :invalid_message)
          refute Map.has_key?(cron_specs, :invalid_message)
        end)

      assert log =~ "invalid_message"
      GenServer.stop(pid)
    end

    test("cron job with timezone", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-4",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :timezone_test, cron: "0 9 * * *", timezone: "Etc/UTC"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :timezone_test) end)
      assert is_pid(job_pid)
      GenServer.stop(pid)
    end

    test("invalid cron directive is isolated and agent survives", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-4b",
          aikido: aikido
        )

      ref = Process.monitor(pid)

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_cron, cron: "definitely-not-a-cron"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      assert Process.alive?(pid)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_cron)
      refute Map.has_key?(cron_specs, :invalid_cron)
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test("invalid timezone directive is isolated and agent survives", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-4c",
          aikido: aikido
        )

      ref = Process.monitor(pid)

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :invalid_tz, cron: "0 9 * * *", timezone: "Invalid/Nowhere"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      assert Process.alive?(pid)

      {:ok, %{cron_jobs: cron_jobs, cron_specs: cron_specs}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{cron_jobs: s.cron_jobs, cron_specs: s.cron_specs}}
        end)

      refute Map.has_key?(cron_jobs, :invalid_tz)
      refute Map.has_key?(cron_specs, :invalid_tz)
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test("auto-generates job_id if not provided", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-5",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{type: "register_cron", source: "/test", data: %{cron: "* * * * *"}})

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      cron_jobs =
        await_state_value(pid, fn s ->
          if map_size(s.cron_jobs) == 1 do
            s.cron_jobs
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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-9a",
          aikido: aikido
        )

      server_ref = Process.monitor(pid)

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :restartable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      original_job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :restartable) end)
      assert is_pid(original_job_pid)
      assert Process.alive?(original_job_pid)
      Process.exit(original_job_pid, :kill)

      restarted_job_pid =
        await_state_value(
          pid,
          fn s ->
            new_pid = Map.get(s.cron_jobs, :restartable)

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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-9b",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :gone_runtime, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :gone_runtime) end)
      assert is_pid(job_pid)
      Process.exit(job_pid, :shutdown)

      await_state_value(
        pid,
        fn s ->
          if not Map.has_key?(s.cron_jobs, :gone_runtime) and
               Map.has_key?(s.cron_specs, :gone_runtime) do
            true
          end
        end,
        timeout: 2000
      )

      cancel_signal =
        Jido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :gone_runtime}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(
        pid,
        fn s ->
          if not Map.has_key?(s.cron_jobs, :gone_runtime) and
               not Map.has_key?(s.cron_specs, :gone_runtime) do
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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-6",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :cancellable, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :cancellable) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)

      cancel_signal =
        Jido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :cancellable}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if not Map.has_key?(s.cron_jobs, :cancellable) do
          true
        end
      end)

      AikidoTest.LifecycleWait.await_down(job_pid)
      GenServer.stop(pid)
    end

    test("cancelling non-existent job is safe", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-7",
          aikido: aikido
        )

      cancel_signal =
        Jido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :nonexistent}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if map_size(s.cron_jobs) == 0 do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("can cancel and re-register same job_id", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-8",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :toggle, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s ->
        if Map.has_key?(s.cron_jobs, :toggle) do
          true
        end
      end)

      cancel_signal =
        Jido.Signal.new!(%{type: "cancel_cron", source: "/test", data: %{job_id: :toggle}})

      :ok = Aikido.AgentServer.cast(pid, cancel_signal)

      await_state_value(pid, fn s ->
        if not Map.has_key?(s.cron_jobs, :toggle) do
          true
        end
      end)

      register_signal2 =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :toggle, cron: "@hourly"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal2)
      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :toggle) end)
      assert is_pid(job_pid)
      GenServer.stop(pid)
    end
  end

  describe("cleanup on agent termination") do
    test("cron jobs are cleaned up when agent stops normally", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-10",
          aikido: aikido
        )

      register_signal =
        Jido.Signal.new!(%{
          type: "register_cron",
          source: "/test",
          data: %{job_id: :cleanup_test, cron: "* * * * *"}
        })

      :ok = Aikido.AgentServer.cast(pid, register_signal)
      job_pid = await_state_value(pid, fn s -> Map.get(s.cron_jobs, :cleanup_test) end)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)
      GenServer.stop(pid)
      AikidoTest.LifecycleWait.await_down(job_pid)
    end

    test("multiple cron jobs are all cleaned up on termination", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-11",
          aikido: aikido
        )

      job_ids = [:job1, :job2, :job3]

      for job_id <- job_ids do
        register_signal =
          Jido.Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: job_id, cron: "* * * * *"}
          })

        :ok = Aikido.AgentServer.cast(pid, register_signal)
      end

      cron_jobs =
        await_state_value(pid, fn s ->
          if map_size(s.cron_jobs) == 3 do
            s.cron_jobs
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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-12a",
          aikido: aikido
        )

      {:ok, pid2} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.CronIntegrationTest.CronTestAgent,
          id: "cron-test-12b",
          aikido: aikido
        )

      for pid <- [pid1, pid2] do
        register_signal =
          Jido.Signal.new!(%{
            type: "register_cron",
            source: "/test",
            data: %{job_id: :shared_name, cron: "* * * * *"}
          })

        :ok = Aikido.AgentServer.cast(pid, register_signal)
      end

      job_pid1 = await_state_value(pid1, fn s -> Map.get(s.cron_jobs, :shared_name) end)
      job_pid2 = await_state_value(pid2, fn s -> Map.get(s.cron_jobs, :shared_name) end)
      refute job_pid1 == job_pid2
      assert Process.alive?(job_pid1)
      assert Process.alive?(job_pid2)
      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end
end
