defmodule AgentExamples.TelemetryTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.{Agents, Telemetry}
  @endpoint AgentExamplesWeb.Endpoint

  test "the sidebar opens LiveDashboard with native metrics and system inspection" do
    conn = build_conn()
    {:ok, index, _} = live(conn, "/")
    assert has_element?(index, "#telemetry-dashboard-link[href='/dashboard']")
    {:ok, dashboard, _} = live(conn, "/dashboard/home")
    assert has_element?(dashboard, "a", "Metrics")
    assert has_element?(dashboard, "a", "Processes")
    assert has_element?(dashboard, "a", "Applications")
    refute has_element?(dashboard, "a", "Request Logger")
    {:ok, metrics, _} = live(conn, "/dashboard/metrics?nav=Signals")
    assert render(metrics) =~ "aikido.agent_server.signal.stop.count"
    assert render(metrics) =~ "Signals"
  end

  test "LiveDashboard receives a real agent command through the native telemetry reporter" do
    agent = Agents.counter_start!()
    on_exit(fn -> Agents.counter_stop(agent) end)

    metric =
      Enum.find(
        Telemetry.metrics(),
        &(&1.name == [:aikido, :agent_server, :signal, :stop, :count])
      )

    {:ok, _listener} = Phoenix.LiveDashboard.TelemetryListener.listen(node(), [metric])

    Agents.counter_add!(agent, %{amount: 2})
    assert_receive {:telemetry, [{0, label, 1, _time}]}, 5_000
    assert label =~ "counter.add"
    assert Agents.counter_inspect!(agent.id).count == 2
  end

  test "metric definitions preserve units, filter rejected signals and omit credential metadata" do
    metrics = Telemetry.metrics()
    assert Enum.uniq_by(metrics, & &1.name) == metrics

    assert MapSet.new(Enum.map(metrics, & &1.reporter_options[:nav])) ==
             MapSet.new(~w(Agents Signals Directives AI Ash BEAM))

    refute Enum.any?(
             metrics,
             &Enum.any?(&1.tags, fn tag ->
               tag in [
                 :actor,
                 :tenant,
                 :agent_id,
                 :request_id,
                 :request_options,
                 :request_summary
               ]
             end)
           )

    rejected =
      Enum.find(metrics, &(&1.name == [:aikido, :agent_server, :signal, :rejected, :count]))

    refute rejected.keep.(%{})
    assert rejected.keep.(%{error: :invalid})

    input = Enum.find(metrics, &(&1.name == [:req_llm, :request, :stop, :input_tokens]))
    assert input.measurement.(%{}, %{usage: %{input_tokens: 125}}) == 125
    assert input.measurement.(%{}, %{usage: nil}) == nil

    duration = Enum.find(metrics, &(&1.name == [:req_llm, :request, :stop, :duration]))
    native = System.convert_time_unit(250, :millisecond, :native)
    assert duration.measurement.(%{duration: native}) == 250
  end
end
