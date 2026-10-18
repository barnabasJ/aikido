defmodule AikidoTest.AgentServer.IdentitySignalsTest do
  use AikidoTest.Case, async: false
  alias Aikido.AgentServer

  defmodule WatcherAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "identity_watcher"}}
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

    defp reduce(%Jido.Signal{type: type, data: data}, slice, _opts, _ctx) do
      events = Map.get(slice, :identity_events, [])
      {:ok, %{slice | identity_events: events ++ [%{type: type, data: data}]}, []}
    end
  end

  defmodule WatcherAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("identity_signals_agent")
      path(:app)

      schema do
        attribute(:identity_events, {:array, :term}, default: [])
      end
    end

    signal_routes do
      route(
        "aikido.agent.identity.partition_assigned",
        AikidoTest.AgentServer.IdentitySignalsTest.WatcherAction
      )
    end
  end

  describe("partition_assigned signal") do
    test("emits at startup with the configured partition", %{aikido: aikido}) do
      pid =
        start_server(%{aikido: aikido}, WatcherAgent,
          id: "identity-1",
          partition: :work_partition
        )

      :ok = AgentServer.await_ready(pid)
      {:ok, events} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.app.identity_events} end)

      assert Enum.any?(events, fn e ->
               e.type == "aikido.agent.identity.partition_assigned" and
                 e.data[:partition] == :work_partition
             end)
    end

    test("emits with nil partition when none is set", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, WatcherAgent, id: "identity-2")
      :ok = AgentServer.await_ready(pid)
      {:ok, events} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.app.identity_events} end)

      assert Enum.any?(events, fn e ->
               e.type == "aikido.agent.identity.partition_assigned" and e.data[:partition] == nil
             end)
    end
  end
end
