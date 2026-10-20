defmodule AikidoTest.AgentServer.LifecycleSignalsTest.LifecycleAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "lifecycle_signals_agent"
  end
end

defmodule AikidoTest.AgentServer.LifecycleSignalsTest do
  use AikidoTest.Case, async: false

  describe("await_ready/2") do
    test("returns :ok after the agent emits aikido.agent.lifecycle.ready", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.LifecycleSignalsTest.LifecycleAgent,
          id: "ready-1"
        )

      assert :ok = Aikido.AgentServer.await_ready(pid, timeout: 5000)
    end

    test("is idempotent — subsequent calls return :ok immediately", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.LifecycleSignalsTest.LifecycleAgent,
          id: "ready-2"
        )

      assert :ok = Aikido.AgentServer.await_ready(pid, timeout: 5000)
      assert :ok = Aikido.AgentServer.await_ready(pid, timeout: 100)
    end

    test "returns an error tuple for an unresolvable server reference" do
      assert {:error, _} = Aikido.AgentServer.await_ready("never-started-agent-id", timeout: 100)
    end
  end
end
