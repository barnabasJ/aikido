defmodule AikidoTest.AgentServer.CronTickDeliveryTest.TickCountAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state

    slice =
      if is_map(slice) do
        slice
      else
        %{}
      end

    count = Map.get(slice, :tick_count, 0)
    Aikido.Types.ActionResult.new(state: Map.put(slice, :tick_count, count + 1), directives: [])
  end
end

defmodule AikidoTest.AgentServer.CronTickDeliveryTest.RegisterCronAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params = Map.delete(input.arguments, :state)

    slice = input.arguments.state
    cron_expr = Map.get(params, :cron)
    job_id = Map.get(params, :job_id)

    tick_signal =
      %Aikido.Signal{id: nil, type: "cron.tick", data: %{}, source: "/test/cron"}

    directive = Aikido.Directives.cron(cron_expr, tick_signal, job_id: job_id)
    Aikido.Types.ActionResult.new(state: slice, directives: [directive])
  end
end

defmodule AikidoTest.AgentServer.CronTickDeliveryTest.CronTickAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "cron_tick_agent"
    path :domain

    schema do
      attribute :tick_count, :integer do
        description "Number of scheduled ticks handled by the agent."
        default 0
      end
    end

    route "register_cron",
          {AikidoTest.AgentServer.CronTickDeliveryTest.CronTickAgent, :register_cron}

    route "cron.tick", {AikidoTest.AgentServer.CronTickDeliveryTest.CronTickAgent, :tick_count}
  end

  actions do
    action :tick_count, Aikido.Types.ActionResult do
      argument :state, :term

      run AikidoTest.AgentServer.CronTickDeliveryTest.TickCountAction.Implementation
    end

    action :register_cron, Aikido.Types.ActionResult do
      argument :state, :term
      argument :cron, :string, allow_nil?: false
      argument :job_id, :term

      run AikidoTest.AgentServer.CronTickDeliveryTest.RegisterCronAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.CronTickDeliveryTest do
  @moduledoc """
  Regression test for issue #136: Directives.Cron executor silently fails
  because cast(agent_id, signal) rejects string IDs via resolve_server/1.

  These tests verify that cron ticks actually reach the agent and update state,
  not just that jobs register successfully.
  """
  use AikidoTest.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true

  describe("cron tick delivery (issue #136 regression)") do
    test("cron tick actually delivers signal and updates agent state", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronTickDeliveryTest.CronTickAgent,
          id: unique_id("cron-tick")
        )

      register_signal =
        Aikido.Signal.new!("register_cron", %{job_id: :tick_test, cron: "* * * * * * *"},
          source: "/test"
        )

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s ->
        if Map.has_key?(s.cron_jobs, :tick_test) do
          true
        end
      end)

      await_state_value(
        pid,
        fn s ->
          tc = s.agent.state.domain.tick_count

          if tc > 0 do
            tc
          end
        end,
        timeout: 5000
      )

      GenServer.stop(pid)
    end

    test("cast to PID succeeds where cast to string ID would fail", %{aikido: aikido}) do
      id = unique_id("cron-cast")

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronTickDeliveryTest.CronTickAgent,
          id: id
        )

      tick_signal = Aikido.Signal.new!("cron.tick", %{}, source: "/test/cron")
      assert :ok = Aikido.AgentServer.cast(pid, tick_signal)

      await_state_value(pid, fn s ->
        if s.agent.state.domain.tick_count == 1 do
          true
        end
      end)

      assert {:error, {:invalid_server, _}} =
               Aikido.AgentServer.call(id, tick_signal, fn s -> {:ok, s.agent} end)

      GenServer.stop(pid)
    end

    test("multiple cron ticks accumulate state changes", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.CronTickDeliveryTest.CronTickAgent,
          id: unique_id("cron-multi")
        )

      register_signal =
        Aikido.Signal.new!("register_cron", %{job_id: :multi_tick, cron: "* * * * * * *"},
          source: "/test"
        )

      :ok = Aikido.AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s ->
        if Map.has_key?(s.cron_jobs, :multi_tick) do
          true
        end
      end)

      await_state_value(
        pid,
        fn s ->
          tc = s.agent.state.domain.tick_count

          if tc >= 2 do
            tc
          end
        end,
        timeout: 5000
      )

      GenServer.stop(pid)
    end
  end
end
