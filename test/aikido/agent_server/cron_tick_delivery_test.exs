defmodule AikidoTest.AgentServer.CronTickDeliveryTest do
  @moduledoc "Regression test for issue #136: Directives.Cron executor silently fails\nbecause cast(agent_id, signal) rejects string IDs via resolve_server/1.\n\nThese tests verify that cron ticks actually reach the agent and update state,\nnot just that jobs register successfully.\n"
  use AikidoTest.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true
  alias Aikido.AgentServer
  alias Aikido.Directives
  alias Jido.Signal

  # ---------------------------------------------------------------------------
  # Test Actions
  # ---------------------------------------------------------------------------

  defmodule TickCountAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "tick_count"}}
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

    defp reduce(_signal, slice, _opts, _ctx) do
      slice =
        if is_map(slice) do
          slice
        else
          %{}
        end

      count = Map.get(slice, :tick_count, 0)
      {:ok, Map.put(slice, :tick_count, count + 1), []}
    end
  end

  defmodule RegisterCronAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "register_cron"}}
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

    defp reduce(%Jido.Signal{data: params}, slice, _opts, _ctx) do
      cron_expr = Map.get(params, :cron)
      job_id = Map.get(params, :job_id)
      tick_signal = Signal.new!("cron.tick", %{}, source: "/test/cron")
      directive = Directives.cron(cron_expr, tick_signal, job_id: job_id)
      {:ok, slice, [directive]}
    end
  end

  # ---------------------------------------------------------------------------
  # Test Agent
  # ---------------------------------------------------------------------------

  defmodule CronTickAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("cron_tick_agent")
      path(:domain)

      schema do
        attribute(:tick_count, :integer, default: 0)
      end
    end

    signal_routes do
      route("register_cron", RegisterCronAction)
      route("cron.tick", TickCountAction)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe("cron tick delivery (issue #136 regression)") do
    test("cron tick actually delivers signal and updates agent state", %{aikido: aikido}) do
      # Use extended 7-field cron: fires every second
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTickAgent,
          id: unique_id("cron-tick"),
          aikido: aikido
        )

      register_signal =
        Signal.new!("register_cron", %{job_id: :tick_test, cron: "* * * * * * *"},
          source: "/test"
        )

      :ok = AgentServer.cast(pid, register_signal)

      # Wait for the cron job to register
      await_state_value(pid, fn s ->
        if Map.has_key?(s.cron_jobs, :tick_test) do
          true
        end
      end)

      # The actual regression: before the fix, ticks would silently fail
      # because cast(string_id, signal) was rejected by resolve_server/1.
      # With the fix, ticks should deliver and increment tick_count.
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
      # This test directly verifies the root cause: string IDs are rejected
      id = unique_id("cron-cast")
      {:ok, pid} = AgentServer.start_link(agent_module: CronTickAgent, id: id, aikido: aikido)
      tick_signal = Signal.new!("cron.tick", %{}, source: "/test/cron")

      # Cast with PID should succeed (the fix)
      assert :ok = AgentServer.cast(pid, tick_signal)

      await_state_value(pid, fn s ->
        if s.agent.state.domain.tick_count == 1 do
          true
        end
      end)

      # Cast with string ID should fail (the original bug)
      assert {:error, {:invalid_server, _}} =
               AgentServer.call(id, tick_signal, fn s -> {:ok, s.agent} end)

      GenServer.stop(pid)
    end

    test("multiple cron ticks accumulate state changes", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: CronTickAgent,
          id: unique_id("cron-multi"),
          aikido: aikido
        )

      register_signal =
        Signal.new!("register_cron", %{job_id: :multi_tick, cron: "* * * * * * *"},
          source: "/test"
        )

      :ok = AgentServer.cast(pid, register_signal)

      await_state_value(pid, fn s ->
        if Map.has_key?(s.cron_jobs, :multi_tick) do
          true
        end
      end)

      # Wait for at least 2 ticks to confirm accumulation
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
