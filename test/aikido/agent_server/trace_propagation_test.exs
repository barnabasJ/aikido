defmodule AikidoTest.AgentServer.TracePropagationTest.EmitAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal =
      struct!(Jido.Signal, id: nil, type: "test.emitted", data: %{value: 42}, source: "/test")

    Aikido.ActionResult.new(state: %{}, directives: [%Aikido.Directives.Emit{signal: signal}])
  end
end

defmodule AikidoTest.AgentServer.TracePropagationTest.EmitAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :emit, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServer.TracePropagationTest.EmitAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.TracePropagationTest.TracedAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "traced_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :received_signals, {:array, :term}, default: []
    end
  end

  signal_routes do
    route "increment", AikidoTest.TestActions.IncrementAction
    route "emit", AikidoTest.AgentServer.TracePropagationTest.EmitAction
  end
end

defmodule AikidoTest.AgentServer.TracePropagationTest do
  use AikidoTest.Case, async: false

  describe("signal ingress tracing") do
    test("signal without trace gets root trace added", context) do
      test_pid = self()
      handler_id = "trace-ingress-test-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :agent_server, :signal, :start],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.TracePropagationTest.TracedAgent,
          aikido: context.aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      assert Aikido.Tracing.Trace.get(signal) == nil
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry, metadata}, 1000
      assert is_binary(metadata[:aikido_trace_id])
      assert is_binary(metadata[:aikido_span_id])
      :telemetry.detach(handler_id)
      GenServer.stop(pid)
    end

    test("signal with existing trace preserves trace_id", context) do
      test_pid = self()
      handler_id = "trace-preserve-test-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :agent_server, :signal, :start],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.TracePropagationTest.TracedAgent,
          aikido: context.aikido
        )

      ctx = Aikido.Tracing.Trace.new_root()
      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, traced_signal} = Aikido.Tracing.Trace.put(signal, ctx)
      {:ok, _agent} = Aikido.AgentServer.call(pid, traced_signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry, metadata}, 1000
      assert metadata[:aikido_trace_id] == ctx.trace_id
      assert metadata[:aikido_span_id] == ctx.span_id
      :telemetry.detach(handler_id)
      GenServer.stop(pid)
    end
  end

  describe("directive trace propagation") do
    test("emit directive adds child trace to emitted signal", context) do
      test_pid = self()
      handler_id = "trace-emit-test-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :agent_server, :directive, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:directive_type] == "Emit" do
            send(test_pid, {:telemetry, metadata})
          end
        end,
        nil
      )

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.TracePropagationTest.TracedAgent,
          aikido: context.aikido
        )

      ctx = Aikido.Tracing.Trace.new_root()
      signal = Jido.Signal.new!("emit", %{}, source: "/test")
      {:ok, traced_signal} = Aikido.Tracing.Trace.put(signal, ctx)
      {:ok, _agent} = Aikido.AgentServer.call(pid, traced_signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry, metadata}, 1000
      assert metadata[:aikido_trace_id] == ctx.trace_id
      :telemetry.detach(handler_id)
      GenServer.stop(pid)
    end
  end

  describe("telemetry trace metadata") do
    test("signal telemetry includes all trace fields", context) do
      test_pid = self()
      handler_id = "trace-metadata-test-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :agent_server, :signal, :start],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.TracePropagationTest.TracedAgent,
          aikido: context.aikido
        )

      parent_ctx = Aikido.Tracing.Trace.new_root()
      child_ctx = Aikido.Tracing.Trace.child_of(parent_ctx, "parent-signal-id")
      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, traced_signal} = Aikido.Tracing.Trace.put(signal, child_ctx)
      {:ok, _agent} = Aikido.AgentServer.call(pid, traced_signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry, metadata}, 1000
      assert metadata[:aikido_trace_id] == parent_ctx.trace_id
      assert metadata[:aikido_span_id] == child_ctx.span_id
      assert metadata[:aikido_parent_span_id] == parent_ctx.span_id
      assert metadata[:aikido_causation_id] == "parent-signal-id"
      :telemetry.detach(handler_id)
      GenServer.stop(pid)
    end

    test("directive telemetry includes trace fields", context) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServer.TracePropagationTest.TracedAgent,
          aikido: context.aikido
        )

      test_pid = self()
      handler_id = "trace-directive-metadata-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :agent_server, :directive, :start],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      ctx = Aikido.Tracing.Trace.new_root()
      signal = Jido.Signal.new!("emit", %{}, source: "/test")
      {:ok, traced_signal} = Aikido.Tracing.Trace.put(signal, ctx)
      {:ok, _agent} = Aikido.AgentServer.call(pid, traced_signal, fn s -> {:ok, s.agent} end)
      metadata = wait_for_trace(ctx.trace_id)
      assert metadata[:aikido_trace_id] == ctx.trace_id
      assert metadata[:aikido_span_id] == ctx.span_id
      :telemetry.detach(handler_id)
      GenServer.stop(pid)
    end

    defp wait_for_trace(trace_id) do
      receive do
        {:telemetry, %{aikido_trace_id: ^trace_id} = metadata} -> metadata
        {:telemetry, _other} -> wait_for_trace(trace_id)
      after
        1000 -> flunk("did not receive directive telemetry for trace #{trace_id}")
      end
    end
  end
end
