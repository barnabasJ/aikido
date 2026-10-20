defmodule Aikido.RouterSubscriptionTest.Reducer do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | count: input.arguments.state.count + 1}
    )
  end
end

defmodule Aikido.RouterSubscriptionTest.Agent do
  use Aikido.Agent

  agent do
    name "router_subscription"

    schema do
      attribute :count, :integer, default: 0
    end

    route "event.**", :increment
  end

  actions do
    action :increment, Aikido.Types.ActionResult do
      argument :state, :term
      run Aikido.RouterSubscriptionTest.Reducer
    end
  end
end

defmodule Aikido.RouterSubscriptionTest do
  use AikidoTest.Case, async: false
  alias Aikido.AgentServer

  test "compiled wildcard subscription keeps skip, observes post-state and retires once", %{
    aikido: aikido
  } do
    {:ok, pid} = AikidoTest.Case.start_test_agent(aikido, Aikido.RouterSubscriptionTest.Agent)
    :ok = AgentServer.await_ready(pid)

    {:ok, ref} =
      AgentServer.subscribe(
        pid,
        "event.*.**",
        fn state ->
          case state.agent.state.state.count do
            1 -> :skip
            count -> {:ok, count}
          end
        end,
        once: true
      )

    assert {:ok, {"event", "*", "**"}} =
             AgentServer.state(pid, &{:ok, &1.signal_subscribers[ref].pattern_compiled})

    assert {:ok, 1} =
             AgentServer.call(
               pid,
               Aikido.Signal.new!("event.first", %{}),
               &{:ok, &1.agent.state.state.count}
             )

    refute_received {:aikido_subscription, ^ref, _}

    assert {:ok, 2} =
             AgentServer.call(
               pid,
               Aikido.Signal.new!("event.second.done", %{}),
               &{:ok, &1.agent.state.state.count}
             )

    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, 2}}}
    assert {:ok, 0} = AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
  end

  test "exact subscriptions reject prefixes and invalid patterns install nothing", %{
    aikido: aikido
  } do
    {:ok, pid} = AikidoTest.Case.start_test_agent(aikido, Aikido.RouterSubscriptionTest.Agent)
    :ok = AgentServer.await_ready(pid)
    {:ok, ref} = AgentServer.subscribe(pid, "event", fn _ -> {:ok, :hit} end, once: true)
    assert {:ok, _} = AgentServer.call(pid, Aikido.Signal.new!("event.first", %{}), &{:ok, &1.id})
    refute_received {:aikido_subscription, ^ref, _}

    assert {:error, {:invalid_pattern, %Aikido.Error.RoutingError{}}} =
             AgentServer.subscribe(pid, "event.**.**", fn _ -> :skip end)

    assert {:ok, 1} = AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
    assert {:ok, _} = AgentServer.call(pid, Aikido.Signal.new!("event", %{}), &{:ok, &1.id})
    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, :hit}}}
  end

  test "subscription results can be sent directly to another process", %{aikido: aikido} do
    {:ok, pid} = AikidoTest.Case.start_test_agent(aikido, Aikido.RouterSubscriptionTest.Agent)
    :ok = AgentServer.await_ready(pid)
    parent = self()

    target =
      spawn(fn ->
        receive do
          message -> send(parent, {:target_received, self(), message})
        end
      end)

    on_exit(fn -> if Process.alive?(target), do: Process.exit(target, :kill) end)

    {:ok, ref} =
      AgentServer.subscribe(pid, "event.**", &{:ok, &1.agent.state.state.count},
        once: true,
        target: target
      )

    assert {:ok, 1} =
             AgentServer.call(
               pid,
               Aikido.Signal.new!("event.direct", %{}),
               &{:ok, &1.agent.state.state.count}
             )

    assert_receive {:target_received, ^target, {:aikido_subscription, ^ref, %{result: {:ok, 1}}}}
    assert {:ok, 0} = AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
  end

  test "unmatched signals retain tagged errors and system stop fallback remains available", %{
    aikido: aikido
  } do
    {:ok, pid} = AikidoTest.Case.start_test_agent(aikido, Aikido.RouterSubscriptionTest.Agent)
    :ok = AgentServer.await_ready(pid)

    assert {:error, _} =
             AgentServer.call(pid, Aikido.Signal.new!("unmatched", %{}), &{:ok, &1.id})

    monitor = Process.monitor(pid)

    assert {:ok, :stopped} =
             AgentServer.call(pid, Aikido.Signal.new!("aikido.agent.stop", %{}), fn _ ->
               {:ok, :stopped}
             end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end
end
