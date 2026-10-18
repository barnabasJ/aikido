defmodule AikidoTest.AgentServerStopLogTest.StopTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{}, directives: [%Aikido.Directives.Stop{reason: :normal}])
  end
end

defmodule AikidoTest.AgentServerStopLogTest.StopTestAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "stop_test"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerStopLogTest.StopTestAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServerStopLogTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "test_agent"
  end

  signal_routes do
    route "stop_test", AikidoTest.AgentServerStopLogTest.StopTestAction
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
          Aikido.AgentServer.start_link(
            agent_module: AikidoTest.AgentServerStopLogTest.TestAgent,
            aikido: aikido
          )

        ref = Process.monitor(pid)
        signal = Jido.Signal.new!("stop_test", %{}, source: "/test")
        Aikido.AgentServer.cast(pid, signal)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end)

    assert log =~ "received {:stop, :normal"
    assert log =~ "This is a HARD STOP"
  end
end
