defmodule AgentExamples.TelemetryTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.{Agents, Telemetry}
  @endpoint AgentExamplesWeb.Endpoint

  test "the sidebar opens LiveDashboard with native metrics and system inspection" do
    conn = build_conn()
    {:ok, index, _} = live(conn, "/")
    assert has_element?(index, "#telemetry-dashboard-link[href='/dashboard/aikido']")
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

  test "native ReqLLM usage processing reaches the token charts" do
    metrics =
      Enum.filter(
        Telemetry.metrics(),
        &(List.last(&1.name) in [:input_tokens, :output_tokens, :reasoning_tokens, :total_cost])
      )

    {:ok, _listener} = Phoenix.LiveDashboard.TelemetryListener.listen(node(), metrics)
    model = ReqLLM.model!("openai:gpt-4o")
    request = Req.new() |> Req.Request.put_private(:req_llm_model, model)

    response = %Req.Response{
      status: 200,
      body: %{
        "usage" => %{
          "prompt_tokens" => 125,
          "completion_tokens" => 42,
          "completion_tokens_details" => %{"reasoning_tokens" => 7}
        }
      }
    }

    {_request, response} = ReqLLM.Step.Usage.handle({request, response})
    assert response.private.req_llm.usage.tokens.input_tokens == 125
    context = ReqLLM.Telemetry.new_context(model, [], operation: :chat, mode: :sync)
    ReqLLM.Telemetry.stop_request(context, response)

    assert_receive {:telemetry, points}, 5_000

    values =
      Map.new(points, fn {index, _label, value, _time} ->
        {List.last(Enum.at(metrics, index).name), value}
      end)

    assert values.input_tokens == 125
    assert values.output_tokens == 42
    assert values.reasoning_tokens == 7
    assert values.total_cost > 0
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
    assert input.measurement.(%{}, %{usage: %{tokens: %{input_tokens: 125}}}) == 125
    assert input.measurement.(%{}, %{usage: %{tokens: %{input: 125}}}) == 125
    assert input.measurement.(%{}, %{usage: nil}) == nil

    cost = Enum.find(metrics, &(&1.name == [:req_llm, :request, :stop, :total_cost]))
    assert cost.measurement.(%{}, %{usage: %{tokens: %{}, cost: 0.25}}) == 0.25

    assert cost.measurement.(%{}, %{
             usage: %{tokens: %{input_tokens: 125}, pricing: %{status: :unknown}}
           }) == nil

    duration = Enum.find(metrics, &(&1.name == [:req_llm, :request, :stop, :duration]))
    native = System.convert_time_unit(250, :millisecond, :native)
    assert duration.measurement.(%{duration: native}) == 250
  end
end
