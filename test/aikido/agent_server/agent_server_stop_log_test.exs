defmodule AikidoTest.AgentServerStopLogTest.StopTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{},
      directives: [%Aikido.Directives.Stop{reason: :normal}]
    )
  end
end

defmodule AikidoTest.AgentServerStopLogTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "test_agent"
    route "stop_test", {AikidoTest.AgentServerStopLogTest.TestAgent, :stop_test}
  end

  actions do
    action :stop_test, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServerStopLogTest.StopTestAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServerStopLogTest do
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test("Stop directive with normal reason logs warning", %{aikido: aikido}) do
    log =
      capture_log(fn ->
        {:ok, pid} =
          AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerStopLogTest.TestAgent)

        ref = Process.monitor(pid)
        signal = Aikido.Signal.new!("stop_test", %{}, source: "/test")
        Aikido.AgentServer.cast(pid, signal)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end)

    assert log =~ "received {:stop, :normal"
    assert log =~ "This is a HARD STOP"
  end
end
