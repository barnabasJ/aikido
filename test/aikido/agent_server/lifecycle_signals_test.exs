defmodule AikidoTest.AgentServer.LifecycleSignalsTest do
  use AikidoTest.Case, async: false

  alias Aikido.AgentServer

  defmodule LifecycleAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "lifecycle_signals_agent"
    end
  end

  setup ctx do
    # Subscribe to our own pid for capture
    {:ok, ctx}
  end

  describe "await_ready/2" do
    test "returns :ok after the agent emits aikido.agent.lifecycle.ready", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          aikido: aikido,
          agent_module: LifecycleAgent,
          id: "ready-1"
        )

      assert :ok = AgentServer.await_ready(pid, timeout: 5_000)
    end

    test "is idempotent — subsequent calls return :ok immediately", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          aikido: aikido,
          agent_module: LifecycleAgent,
          id: "ready-2"
        )

      assert :ok = AgentServer.await_ready(pid, timeout: 5_000)
      assert :ok = AgentServer.await_ready(pid, timeout: 100)
    end

    test "returns an error tuple for an unresolvable server reference" do
      assert {:error, _} = AgentServer.await_ready("never-started-agent-id", timeout: 100)
    end
  end
end
