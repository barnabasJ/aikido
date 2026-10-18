defmodule AikidoTest.AgentServerStopLogTest do
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog
  alias Aikido.AgentServer
  alias Aikido.Directives
  alias Jido.Signal

  defmodule StopTestAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "stop_test"}}
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
      {:ok, %{}, [%Directives.Stop{reason: :normal}]}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("test_agent")
    end

    signal_routes do
      route("stop_test", StopTestAction)
    end
  end

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test("Stop directive with normal reason logs warning", %{aikido: aikido}) do
    log =
      capture_log(fn ->
        {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
        ref = Process.monitor(pid)
        signal = Signal.new!("stop_test", %{}, source: "/test")
        AgentServer.cast(pid, signal)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end)

    assert log =~ "received {:stop, :normal"
    assert log =~ "This is a HARD STOP"
  end
end
