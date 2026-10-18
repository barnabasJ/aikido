defmodule AikidoTest.Signal.CallTest do
  @moduledoc "Tests for `Aikido.Signal.Call` — the synchronous request/reply primitive\nover signals.\n\nCovers the happy path (query → `%Reply{}` directive → reply signal) and\nthe error modes the primitive promises:\n\n* `{:error, :noproc}` — target process dies (or was already dead) before\n  replying. Implemented via `Process.monitor/1` so the caller unblocks\n  immediately instead of waiting out the full timeout.\n* `{:error, :timeout}` — no reply arrived within the configured window.\n* `{:error, :not_found}` — server name/via does not resolve.\n* `{:error, :invalid_server}` — unsupported server reference type.\n"
  use AikidoTest.Case, async: true
  alias Aikido.AgentServer
  alias Jido.Signal
  alias Aikido.Signal.Call

  defmodule EchoAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "echo_action"}}
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

    defp reduce(signal, _slice, _opts, _ctx) do
      directive = Call.reply(signal, "aikido.test.echo.reply", %{ok: true})
      {:ok, %{}, List.wrap(directive)}
    end
  end

  defmodule SilentAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "silent_action"}}
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

    defp reduce(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
    end
  end

  defmodule CallTestAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("call_test_agent")
    end

    signal_routes do
      route("aikido.test.echo", EchoAction)
      route("aikido.test.silent", SilentAction)
    end
  end

  describe("call/3") do
    test "the built-in children action replies without changing domain state", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CallTestAgent, id: "children-query", aikido: aikido)

      :ok = AgentServer.await_ready(pid)
      assert {:ok, before_state} = AgentServer.state(pid, &{:ok, &1.agent.state})
      query = Signal.new!("aikido.agent.query.children", %{}, source: "/test")

      assert {:ok, reply} = Call.call(pid, query)
      assert reply.type == "aikido.agent.query.children.reply"
      assert reply.subject == query.id
      assert reply.data == %{children: %{}}
      assert {:ok, ^before_state} = AgentServer.state(pid, &{:ok, &1.agent.state})
      GenServer.stop(pid)
    end

    test("returns the reply signal on the happy path", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: CallTestAgent, id: "echo", aikido: aikido)
      query = Signal.new!("aikido.test.echo", %{}, source: "/test")
      assert {:ok, reply} = Call.call(pid, query)
      assert reply.type == "aikido.test.echo.reply"
      assert reply.subject == query.id
      assert reply.data == %{ok: true}
      GenServer.stop(pid)
    end

    test(
      "returns {:error, :timeout} when the action does not reply within the window",
      %{aikido: aikido}
    ) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CallTestAgent, id: "silent", aikido: aikido)

      query = Signal.new!("aikido.test.silent", %{}, source: "/test")
      assert {:error, :timeout} = Call.call(pid, query, timeout: 50)
      GenServer.stop(pid)
    end

    test "returns {:error, :noproc} when the target process is already dead" do
      fake_pid = spawn(fn -> :ok end)
      # Wait for the process to actually exit so Process.monitor/1 fires DOWN
      # with :noproc immediately.
      ref = Process.monitor(fake_pid)

      receive do
        {:DOWN, ^ref, :process, ^fake_pid, _} -> :ok
      after
        1000 -> flunk("spawned process did not exit in time")
      end

      query = Signal.new!("aikido.test.echo", %{}, source: "/test")

      # Default timeout is 5s; the monitor-based fail-fast should cut that
      # short to well under a second.
      start = System.monotonic_time(:millisecond)
      assert {:error, :noproc} = Call.call(fake_pid, query)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 500,
             "expected :noproc to fail fast (<500ms); took #{elapsed}ms"
    end

    test(
      "returns {:error, :noproc} when the target process dies mid-call",
      %{aikido: aikido}
    ) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: CallTestAgent, id: "dying", aikido: aikido)

      # Unlink so our kill doesn't also take down the test process.
      Process.unlink(pid)

      # Fire a query that never gets answered (SilentAction) and kill the
      # server while the caller is blocked in the receive.
      caller = self()

      task =
        Task.async(fn ->
          query = Signal.new!("aikido.test.silent", %{}, source: "/test")
          send(caller, :sent)
          Call.call(pid, query, timeout: 5000)
        end)

      receive do
        :sent -> :ok
      after
        500 -> flunk("task did not send the query in time")
      end

      # Give the cast a moment to land before killing the server.
      Process.sleep(20)
      Process.exit(pid, :kill)
      assert {:error, :noproc} = Task.await(task, 1000)
    end

    test "returns {:error, :not_found} for an unregistered name" do
      query = Signal.new!("aikido.test.echo", %{}, source: "/test")
      assert {:error, :not_found} = Call.call(:nonexistent_agent_name, query)
    end

    test "returns {:error, :invalid_server} for unsupported server references" do
      query = Signal.new!("aikido.test.echo", %{}, source: "/test")
      assert {:error, :invalid_server} = Call.call(123, query)
    end
  end
end
