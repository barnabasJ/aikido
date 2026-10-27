defmodule AikidoTest.Actions.StatePreservationTest.Signals.Observe do
  use Aikido.Signal

  signal do
    type "test.noop"
  end
end

defmodule AikidoTest.Actions.StatePreservationTest.Actions.PreserveCount do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end
end

defmodule AikidoTest.Actions.StatePreservationTest.Agent do
  use Aikido.Agent

  agent do
    name "effect_state_preservation"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 42
      end
    end

    route AikidoTest.Actions.StatePreservationTest.Signals.Observe,
          AikidoTest.Actions.StatePreservationTest.Actions.PreserveCount
  end
end

defmodule AikidoTest.Actions.StatePreservationTest do
  use AikidoTest.Case, async: true

  test "noop routed through the AgentServer preserves initialized state", context do
    pid = start_server(context, __MODULE__.Agent)

    assert {:ok, %{count: 42}} =
             Aikido.AgentServer.call(pid, signal("test.noop"), &{:ok, &1.agent.state.state})
  end

  test "native routed broadcast delivers a materialized event and preserves state", context do
    pubsub = Module.concat(context.aikido, PubSub)
    start_supervised!({Phoenix.PubSub, name: pubsub})
    topic = "work.available"
    :ok = Phoenix.PubSub.subscribe(pubsub, topic)
    pid = start_server(context, AikidoTest.TestAgents.NotificationPublisher)
    assert {:ok, before} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})

    assert {:ok, after_broadcast} =
             Aikido.AgentServer.call(
               pid,
               signal("test.broadcast", %{
                 pubsub: pubsub,
                 topic: topic,
                 signal_type: "work.available",
                 payload: %{job: "one"},
                 source: "/test-broadcast"
               }),
               &{:ok, &1.agent.state}
             )

    assert after_broadcast === before

    assert_receive %Aikido.Signal{
                     id: id,
                     time: time,
                     type: "work.available",
                     data: %{job: "one"},
                     source: "/test-broadcast"
                   },
                   2_000

    assert is_binary(id) and id != ""
    assert {:ok, _, _} = DateTime.from_iso8601(time)
  end
end
