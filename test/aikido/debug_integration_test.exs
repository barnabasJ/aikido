defmodule AikidoTest.DebugIntegrationTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "debug_integration_test_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end
  end
end

defmodule AikidoTest.DebugIntegrationTest do
  use AikidoTest.Case, async: false

  setup context do
    Aikido.Debug.disable(context.aikido)
    on_exit(fn -> Aikido.Debug.disable(context.aikido) end)
    context
  end

  describe("instance-level debug enables agent recording") do
    test("debug mode enables event recording for all agents in instance", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.DebugIntegrationTest.TestAgent)
      {:error, :debug_not_enabled} = Aikido.AgentServer.recent_events(pid)
      Aikido.Debug.enable(aikido, :on)
      signal = signal("aikido.test.debug", %{value: 42})
      Aikido.AgentServer.cast(pid, signal)

      {:ok, events} = Aikido.AgentServer.recent_events(pid)
      assert is_list(events)
    end

    test("disabling debug stops recording", %{aikido: aikido}) do
      Aikido.Debug.enable(aikido, :on)
      pid = start_server(%{aikido: aikido}, AikidoTest.DebugIntegrationTest.TestAgent)
      {:ok, _events} = Aikido.AgentServer.recent_events(pid)
      Aikido.Debug.disable(aikido)
      {:error, :debug_not_enabled} = Aikido.AgentServer.recent_events(pid)
    end
  end

  describe("debug_max_events from config") do
    test("agent state respects configured max events", %{aikido: aikido}) do
      pid =
        start_server(%{aikido: aikido}, AikidoTest.DebugIntegrationTest.TestAgent, debug: true)

      {:ok, debug_max_events} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.debug_max_events} end)

      assert debug_max_events == Aikido.Config.Defaults.debug_max_events()
    end
  end

  describe("aikido_instance in telemetry metadata") do
    test("telemetry events include aikido_instance", %{aikido: aikido}) do
      test_pid = self()
      handler_id = "test-instance-meta-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:aikido, :agent_server, :signal, :start], [:aikido, :agent_server, :signal, :stop]],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:meta, metadata}) end,
        nil
      )

      pid = start_server(%{aikido: aikido}, AikidoTest.DebugIntegrationTest.TestAgent)
      signal = signal("aikido.test.meta", %{})
      Aikido.AgentServer.cast(pid, signal)
      assert_receive {:meta, metadata}, 1000
      assert metadata[:aikido_instance] == aikido
      :telemetry.detach(handler_id)
    end

    test("telemetry and debug events include aikido_partition", %{aikido: aikido}) do
      test_pid = self()
      handler_id = "test-partition-meta-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:aikido, :agent_server, :signal, :start], [:aikido, :agent_server, :signal, :stop]],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:partition_meta, metadata})
        end,
        nil
      )

      pid =
        start_server(%{aikido: aikido}, AikidoTest.DebugIntegrationTest.TestAgent,
          debug: true,
          partition: :blue
        )

      signal = signal("aikido.test.partition", %{})
      Aikido.AgentServer.cast(pid, signal)
      assert_receive {:partition_meta, metadata}, 1000
      assert metadata[:aikido_instance] == aikido
      assert metadata[:aikido_partition] == :blue

      {:ok, events} = Aikido.AgentServer.recent_events(pid)
      assert Enum.any?(events, &(&1.aikido_partition == :blue))

      :telemetry.detach(handler_id)
    end
  end
end
