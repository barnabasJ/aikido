defmodule AgentExamples.TelemetryOverviewTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias AgentExamples.Telemetry.{Observations, SystemSnapshot}
  @endpoint AgentExamplesWeb.Endpoint

  test "overview includes live agents and commands processed before the page opens" do
    before = Observations.snapshot()
    agent = AgentExamples.Agents.counter_start!()
    on_exit(fn -> AgentExamples.Agents.counter_stop(agent) end)
    AgentExamples.Agents.counter_add!(agent, %{amount: 3})

    snapshot = SystemSnapshot.read()
    assert snapshot.runtime.local_agents >= 1
    assert snapshot.totals.signals_sent > before.totals.signals_sent
    assert snapshot.totals.signals_processed > before.totals.signals_processed
    assert Enum.any?(snapshot.runtime.agents, &(&1.id == agent.id and &1.pid == agent.pid))

    {:ok, page, _} = live(build_conn(), "/dashboard/aikido")
    assert has_element?(page, "#aikido-system-overview")
    assert render(page) =~ agent.id
    assert render(page) =~ "Actual processes under the native supervisor"
    assert render(page) =~ "Retained while this application is running"
  end

  test "native request telemetry retains durations and usage while excluding payloads and keys" do
    before = Observations.snapshot()
    context = request_context()
    context = ReqLLM.Telemetry.start_request(context, :generate_text)
    during = Observations.snapshot()
    assert during.active_count == before.active_count + 1
    assert Enum.any?(during.active, &(&1.request_id == context.request_id and &1.elapsed_ms >= 0))

    ReqLLM.Telemetry.stop_request(context, %Req.Response{status: 200, body: %{}},
      usage: %{input_tokens: 12, output_tokens: 4, reasoning_tokens: 2},
      finish_reason: :length
    )

    finished = Observations.snapshot()
    request = Enum.find(finished.recent, &(&1.request_id == context.request_id))
    assert request.outcome == :finished
    assert request.model == "gpt-4o"
    assert request.finish_reason == "length"
    assert request.duration_ms >= 0
    assert request.usage.input_tokens == 12
    assert finished.usage.input_tokens == Map.get(before.usage, :input_tokens, 0) + 12
    assert finished.missing_cost == before.missing_cost + 1
    refute inspect(finished, limit: :infinity) =~ "private-provider-key"
    refute inspect(finished, limit: :infinity) =~ "private-request-prompt"

    {:ok, page, _} = live(build_conn(), "/dashboard/aikido")
    assert has_element?(page, "#aikido-provider-requests", "openai / gpt-4o")
    assert has_element?(page, "#aikido-provider-requests", "12 / 4")
    assert has_element?(page, "#aikido-provider-requests", "Finish: length")
    assert render(page) =~ "finished requests without pricing"
    refute render(page) =~ "private-provider-key"
  end

  test "HTTP failures and raised request exceptions remain distinguishable" do
    context = request_context()
    ReqLLM.Telemetry.stop_request(context, %Req.Response{status: 503, body: %{}})

    assert Enum.find(Observations.snapshot().recent, &(&1.request_id == context.request_id)).outcome ==
             :http_error

    context = request_context()
    ReqLLM.Telemetry.exception_request(context, RuntimeError.exception("private-provider-key"))
    snapshot = Observations.snapshot()

    assert Enum.find(snapshot.recent, &(&1.request_id == context.request_id)).outcome ==
             :exception

    refute inspect(snapshot, limit: :infinity) =~ "private-provider-key"
  end

  test "recent provider history remains bounded and reported zero cost stays numeric" do
    for _ <- 1..55 do
      ReqLLM.Telemetry.stop_request(request_context(), %Req.Response{status: 200, body: %{}},
        usage: %{total_cost: 0}
      )
    end

    snapshot = Observations.snapshot()
    assert length(snapshot.recent) == 50
    assert hd(snapshot.recent).usage.total_cost == 0
  end

  test "restarting the observation worker leaves running agents alive and reattaches handlers" do
    agent = AgentExamples.Agents.counter_start!()
    on_exit(fn -> AgentExamples.Agents.counter_stop(agent) end)
    before = Process.whereis(Observations)
    assert :ok = Supervisor.terminate_child(AgentExamples.Telemetry, Observations)
    assert {:ok, after_restart} = Supervisor.restart_child(AgentExamples.Telemetry, Observations)
    refute before == after_restart
    assert Process.alive?(agent.pid)
    AgentExamples.Agents.counter_add!(agent, %{amount: 2})
    assert Observations.snapshot().totals.signals_sent >= 1
    assert AgentExamples.Agents.counter_inspect!(agent.id).count == 2
  end

  defp request_context do
    ReqLLM.Telemetry.new_context(ReqLLM.model!("openai:gpt-4o"),
      api_key: "private-provider-key",
      messages: [ReqLLM.Context.user("private-request-prompt")]
    )
  end
end
