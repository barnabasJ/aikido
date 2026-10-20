defmodule AikidoTest.Signal.CallTest.EchoAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal = input.context.aikido.signal

    directive =
      Aikido.Signal.Call.reply_from_state(
        signal,
        "aikido.test.echo.reply",
        "aikido.test.echo.error",
        {__MODULE__, :build_reply, []}
      )

    directives = List.wrap(directive)

    directives =
      if signal.data[:stop], do: directives ++ [%Aikido.Directives.Stop{}], else: directives

    Aikido.Types.ActionResult.new(state: %{}, directives: directives)
  end

  def build_reply(_runtime), do: {:ok, %{ok: true}}
end

defmodule AikidoTest.Signal.CallTest.SilentAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.Signal.CallTest.CallTestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "call_test_agent"
    route "aikido.test.echo", {AikidoTest.Signal.CallTest.CallTestAgent, :echo_action}
    route "aikido.test.silent", {AikidoTest.Signal.CallTest.CallTestAgent, :silent_action}
  end

  actions do
    action :echo_action, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.Signal.CallTest.EchoAction.Implementation
    end

    action :silent_action, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.Signal.CallTest.SilentAction.Implementation
    end
  end
end

defmodule AikidoTest.Signal.CallTest do
  @moduledoc """
  Tests for `Aikido.Signal.Call` — the synchronous request/reply primitive
  over signals.

  Covers the happy path (query → `%Reply{}` directive → reply signal) and
  the error modes the primitive promises:

  * `{:error, :noproc}` — target process dies (or was already dead) before
    replying. Implemented via `Process.monitor/1` so the caller unblocks
    immediately instead of waiting out the full timeout.
  * `{:error, :timeout}` — no reply arrived within the configured window.
  * `{:error, :not_found}` — server name/via does not resolve.
  * `{:error, :invalid_server}` — unsupported server reference type.
  """
  use AikidoTest.Case, async: false
  require Ash.Tracer

  test "signal calls retain native Ash ancestry through query processing and reply", %{
    aikido: aikido
  } do
    tracer = AikidoTest.Support.TestTracer
    start_supervised!(tracer)

    {:ok, pid} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
        id: "traced-query"
      )

    :ok = Aikido.AgentServer.await_ready(pid)

    query =
      Jido.Signal.new!("aikido.agent.query.children", %{})
      |> Aikido.SignalCtx.put(:tracer, tracer)

    Ash.Tracer.span :custom, "outside.query", tracer do
      parent = tracer.get_span_context()
      assert {:ok, reply} = Aikido.Signal.Call.call(pid, query)
      spans = tracer.get_spans()

      assert {:start, processing, _, "aikido.agent.query.children"} =
               Enum.find(spans, &match?({:start, _, _, "aikido.agent.query.children"}, &1))

      assert {:parent, processing, parent, pid} in spans
      assert Map.has_key?(Aikido.SignalCtx.tracer_context(reply), tracer)
    end
  end

  test "a synchronous reply recipient does not block the agent mailbox", %{aikido: aikido} do
    {:ok, pid} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
        id: "sync-reply"
      )

    test_pid = self()

    recipient =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:signal, reply}} ->
            send(test_pid, {:reply_waiting, self(), reply})

            receive do
              :release -> GenServer.reply(from, :ok)
            end
        end
      end)

    on_exit(fn -> Process.exit(recipient, :kill) end)

    query = %{
      Jido.Signal.new!("aikido.agent.query.children", %{})
      | jido_dispatch: {:pid, target: recipient, delivery_mode: :sync}
    }

    assert :ok = Aikido.AgentServer.cast(pid, query)
    assert_receive {:reply_waiting, ^recipient, reply}, 1_000
    assert reply.subject == query.id

    assert {:ok, :responsive} =
             Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end, timeout: 500)

    send(recipient, :release)
  end

  test "custom reply formatters execute outside the agent", %{aikido: aikido} do
    {:ok, pid} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
        id: "formatted-reply"
      )

    test_pid = self()

    format = fn signal ->
      send(test_pid, {:formatter_waiting, self()})

      receive do
        :release -> {:signal, signal}
      end
    end

    query = %{
      Jido.Signal.new!("aikido.agent.query.children", %{})
      | jido_dispatch: {:pid, target: test_pid, message_format: format}
    }

    assert :ok = Aikido.AgentServer.cast(pid, query)
    assert_receive {:formatter_waiting, worker}, 1_000
    assert worker != pid

    assert {:ok, :responsive} =
             Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end, timeout: 500)

    send(worker, :release)
    assert_receive {:signal, %Jido.Signal{subject: id}}, 1_000
    assert id == query.id
  end

  test "an ordinary PID reply arrives before an immediately following stop", %{aikido: aikido} do
    for n <- 1..20 do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
          id: "reply-stop-#{n}"
        )

      query = Jido.Signal.new!("aikido.test.echo", %{stop: true})
      assert {:ok, %Jido.Signal{subject: id}} = Aikido.Signal.Call.call(pid, query)
      assert id == query.id
    end
  end

  test "supervised dispatch rejection is observable without running the adapter" do
    instance = AikidoTest.Signal.CallTest.FullRuntime

    start_supervised!(
      {Aikido, name: instance, max_tasks: 0, durable: AikidoTest.Case.durable_options()}
    )

    signal = Jido.Signal.new!("test.dispatch", %{})
    agent = Aikido.Agent.new!(id: "full", agent_module: AikidoTest.Signal.CallTest.CallTestAgent)

    runtime = %Aikido.AgentServer.State{
      aikido: instance,
      id: "full",
      agent_module: agent.agent_module,
      agent: agent
    }

    directive = %Aikido.Directives.Emit{signal: signal, dispatch: {:noop, []}}

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert :ok = Aikido.Directive.exec(directive, signal, runtime)
           end) =~ "Could not start signal dispatch: :max_children"
  end

  describe("call/3") do
    test("the built-in children action replies without changing domain state", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
          id: "children-query"
        )

      :ok = Aikido.AgentServer.await_ready(pid)
      assert {:ok, before_state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})
      query = Jido.Signal.new!("aikido.agent.query.children", %{}, source: "/test")
      assert {:ok, reply} = Aikido.Signal.Call.call(pid, query)
      assert reply.type == "aikido.agent.query.children.reply"
      assert reply.subject == query.id
      assert reply.data == %{children: %{}}
      assert {:ok, ^before_state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})
      GenServer.stop(pid)
    end

    test("returns the reply signal on the happy path", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
          id: "echo"
        )

      query = Jido.Signal.new!("aikido.test.echo", %{}, source: "/test")
      assert {:ok, reply} = Aikido.Signal.Call.call(pid, query)
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
          id: "silent"
        )

      query = Jido.Signal.new!("aikido.test.silent", %{}, source: "/test")
      assert {:error, :timeout} = Aikido.Signal.Call.call(pid, query, timeout: 50)
      GenServer.stop(pid)
    end

    test "returns {:error, :noproc} when the target process is already dead" do
      fake_pid = spawn(fn -> :ok end)
      ref = Process.monitor(fake_pid)

      receive do
        {:DOWN, ^ref, :process, ^fake_pid, _} -> :ok
      after
        1000 -> flunk("spawned process did not exit in time")
      end

      query = Jido.Signal.new!("aikido.test.echo", %{}, source: "/test")
      start = System.monotonic_time(:millisecond)
      assert {:error, :noproc} = Aikido.Signal.Call.call(fake_pid, query)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 500,
             "expected :noproc to fail fast (<500ms); took #{elapsed}ms"
    end

    test(
      "returns {:error, :noproc} when the target process dies mid-call",
      %{aikido: aikido}
    ) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.Signal.CallTest.CallTestAgent,
          id: "dying"
        )

      Process.unlink(pid)

      {:ok, ref} =
        Aikido.AgentServer.subscribe(pid, "aikido.test.silent", fn _ -> {:ok, :received} end,
          once: true
        )

      task =
        Task.async(fn ->
          query = Jido.Signal.new!("aikido.test.silent", %{}, source: "/test")
          Aikido.Signal.Call.call(pid, query, timeout: 5000)
        end)

      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, :received}}}, 1000
      Process.exit(pid, :kill)
      assert {:error, :noproc} = Task.await(task, 1000)
    end

    test "returns {:error, :not_found} for an unregistered name" do
      query = Jido.Signal.new!("aikido.test.echo", %{}, source: "/test")
      assert {:error, :not_found} = Aikido.Signal.Call.call(:nonexistent_agent_name, query)
    end

    test "returns {:error, :invalid_server} for unsupported server references" do
      query = Jido.Signal.new!("aikido.test.echo", %{}, source: "/test")
      assert {:error, :invalid_server} = Aikido.Signal.Call.call(123, query)
    end
  end
end
