defmodule AikidoTest.Actions.LifecycleTest do
  use AikidoTest.Case, async: true
  @moduletag capture_log: true

  test "agent's built-in stop route defaults to a normal shutdown", context do
    pid = start_server(context, AikidoTest.TestAgents.Minimal)
    monitor = Process.monitor(pid)

    assert :ok = Aikido.AgentServer.cast(pid, signal("aikido.agent.stop"))
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "agent's built-in stop route propagates a custom failure reason", context do
    pid = start_server(context, AikidoTest.TestAgents.Minimal, restart?: false)
    monitor = Process.monitor(pid)

    assert :ok =
             Aikido.AgentServer.cast(pid, signal("aikido.agent.stop", %{reason: :work_failed}))

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:error, :work_failed}}, 2_000
  end
end
