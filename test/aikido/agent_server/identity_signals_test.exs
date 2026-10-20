defmodule AikidoTest.AgentServer.IdentitySignalsTest.WatcherAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    type = Map.fetch!(input.context.aikido.signal, :type)
    data = input.arguments.data
    slice = input.arguments.state
    events = Map.get(slice, :identity_events, [])

    Aikido.ActionResult.new(
      state: %{slice | identity_events: events ++ [%{type: type, data: data}]},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServer.IdentitySignalsTest.WatcherAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "identity_signals_agent"
    path :app

    schema do
      attribute :identity_events, {:array, :term}, default: []
    end

    route "aikido.agent.identity.partition_assigned",
          {AikidoTest.AgentServer.IdentitySignalsTest.WatcherAgent, :identity_watcher}
  end

  actions do
    action :identity_watcher, Aikido.ActionResult do
      argument :state, :term
      argument :data, :map, allow_nil?: false, default: %{}
      run AikidoTest.AgentServer.IdentitySignalsTest.WatcherAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.IdentitySignalsTest do
  use AikidoTest.Case, async: false

  describe("partition_assigned signal") do
    test("emits at startup with the configured partition", %{aikido: aikido}) do
      pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.IdentitySignalsTest.WatcherAgent,
          id: "identity-1",
          partition: :work_partition
        )

      :ok = Aikido.AgentServer.await_ready(pid)

      {:ok, events} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.app.identity_events} end)

      assert Enum.any?(events, fn e ->
               e.type == "aikido.agent.identity.partition_assigned" and
                 e.data[:partition] == :work_partition
             end)
    end

    test("emits with nil partition when none is set", %{aikido: aikido}) do
      pid =
        start_server(%{aikido: aikido}, AikidoTest.AgentServer.IdentitySignalsTest.WatcherAgent,
          id: "identity-2"
        )

      :ok = Aikido.AgentServer.await_ready(pid)

      {:ok, events} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.app.identity_events} end)

      assert Enum.any?(events, fn e ->
               e.type == "aikido.agent.identity.partition_assigned" and e.data[:partition] == nil
             end)
    end
  end
end
