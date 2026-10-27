defmodule AgentExamples.CronCheckpointTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.{Agents, Playground}
  @endpoint AgentExamplesWeb.Endpoint

  test "a fresh VM restores cron atoms declared only in routed implementations" do
    agent = Agents.cron_clock_start!(%{})
    on_exit(fn -> Agents.cron_clock_stop(agent) end)

    assert {:ok, :registered} =
             Aikido.AgentServer.call_until(
               agent.pid,
               AgentExamples.CronClock.Signals.Enable.new!(%{}),
               "**",
               fn runtime ->
                 if map_size(runtime.agent.state.cron.jobs) == 1,
                   do: {:ok, :registered},
                   else: :skip
               end
             )

    {:ok, envelope} =
      Aikido.AgentServer.state(agent.pid, fn runtime ->
        {:ok,
         Aikido.Durable.AgentServer.dump_state(%{
           runtime: runtime,
           permanent: false,
           options: [agent_module: AgentExamples.CronClock, id: runtime.id]
         })}
      end)

    directory = Path.join(System.tmp_dir!(), "aikido-cold-cron-#{Ash.UUIDv7.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    snapshot = Path.join(directory, "snapshot.json")
    script = Path.join(directory, "restore.exs")
    File.write!(snapshot, Jason.encode!(envelope))

    File.write!(script, """
    {:ok, _} = Application.ensure_all_started(:aikido)
    Code.ensure_loaded!(AgentExamples.CronClock)
    false = :code.is_loaded(AgentExamples.CronClock.Actions.Enable)
    [path] = System.argv()
    saved = path |> File.read!() |> Jason.decode!() |> Aikido.Durable.Snapshot.load()
    {:agent, agent} = saved.agent
    1 = map_size(agent.state.cron.specs)
    IO.puts("COLD_RESTORE_OK")
    """)

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ [script, snapshot],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "COLD_RESTORE_OK"
  end

  test "cron delivers real ticks and cancellation prevents queued ticks changing the count" do
    agent = Agents.cron_clock_start!(%{})
    on_exit(fn -> Agents.cron_clock_stop(agent) end)

    {:ok, ticks} =
      Aikido.AgentServer.subscribe(
        agent.pid,
        "examples.cron_clock.tick",
        fn runtime ->
          {:ok, runtime.agent.state.state.count}
        end,
        once: true
      )

    Agents.cron_clock_enable!(agent)
    assert_receive {:aikido_subscription, ^ticks, %{result: {:ok, count}}}, 5000
    assert count > 0

    {:ok, cancelled} =
      Aikido.AgentServer.subscribe(
        agent.pid,
        "aikido.agent.cron.cancelled",
        fn runtime ->
          {:ok, runtime.agent.state.cron.jobs}
        end,
        once: true
      )

    Agents.cron_clock_disable!(agent)
    assert_receive {:aikido_subscription, ^cancelled, %{result: {:ok, jobs}}}, 5000
    assert jobs == %{}
    before = Agents.cron_clock_inspect!(agent).count
    signal = AgentExamples.CronClock.Signals.Tick.new!(%{})

    assert {:ok, ^before} =
             Aikido.AgentServer.call(agent.pid, signal, &{:ok, &1.agent.state.state.count})
  end

  test "the checkpoint page restores saved state after a signal deliberately kills the process" do
    owner = Ash.UUIDv7.generate()
    conn = build_conn() |> Plug.Test.init_test_session(%{browser_id: owner})
    {:ok, view, _} = live(conn, "/examples/checkpoint")
    {:ok, initial} = Playground.start(owner, "checkpoint", %{})
    on_exit(fn -> Playground.stop(owner, "checkpoint") end)
    assert :ok = Playground.command(owner, "checkpoint", :add, %{amount: 3})
    assert :ok = Playground.stop(owner, "checkpoint")
    {:ok, saved} = Playground.start(owner, "checkpoint", %{})
    assert saved.record.id == initial.record.id
    assert saved.record.pid != initial.record.pid
    assert saved.snapshot.own.count == 3
    assert :ok = Playground.command(owner, "checkpoint", :add, %{amount: 7})

    # Refresh the LiveView using its normal notification before pressing Crash.
    send(view.pid, {:run_updated, owner, "checkpoint"})
    assert has_element?(view, "#checkpoint-count", "10")
    monitor = Process.monitor(saved.record.pid)
    view |> element("#checkpoint-crash") |> render_click()
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5000
    # The LiveView marks the run stopped after its own process monitor fires.
    assert has_element?(view, "#checkpoint-counter")
    await_stopped(owner)
    {:ok, restored} = Playground.start(owner, "checkpoint", %{})
    assert restored.record.id == saved.record.id
    assert restored.record.pid != saved.record.pid
    assert restored.snapshot.own.count == 3
  end

  test "cron page exposes separate start and pause controls" do
    owner = Ash.UUIDv7.generate()
    conn = build_conn() |> Plug.Test.init_test_session(%{browser_id: owner})
    {:ok, view, _} = live(conn, "/examples/cron")
    assert has_element?(view, "#enable-cron[disabled]")
    {:ok, _} = Playground.start(owner, "cron", %{})
    on_exit(fn -> Playground.stop(owner, "cron") end)
    send(view.pid, {:run_updated, owner, "cron"})
    view |> element("#enable-cron") |> render_click()
    assert has_element?(view, "#cron-status", "Running")
    view |> element("#disable-cron") |> render_click()
    assert has_element?(view, "#cron-status", "Paused")
  end

  defp await_stopped(owner) do
    Playground.subscribe()

    if Playground.get(owner, "checkpoint").status != :stopped do
      assert_receive {:run_updated, ^owner, "checkpoint"}, 5000
      await_stopped(owner)
    end
  end
end
