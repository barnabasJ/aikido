defmodule Aikido.RuntimeNativeContractTest.Signals.Invalid do
  use Aikido.Signal

  signal do
    type "invalid.directive"
  end
end

defmodule Aikido.RuntimeNativeContractTest.RawResult do
  use Ash.Resource.Actions.Implementation

  def run(_input, _opts, _context) do
    {:ok,
     %Aikido.Types.ActionResult{
       state: %{count: 99},
       directives: [%Aikido.Directives.Schedule{delay_ms: -1, message: :tick}]
     }}
  end
end

defmodule Aikido.RuntimeNativeContractTest.InvalidDirectiveAgent do
  use Aikido.Agent

  agent do
    name "invalid_directive"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 0
      end
    end

    route Aikido.RuntimeNativeContractTest.Signals.Invalid,
          Aikido.RuntimeNativeContractTest.RawResult
  end
end

defmodule Aikido.RuntimeNativeContractTest.ScopedWorker do
  use Ash.Resource,
    domain: Aikido.RuntimeDomain,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Agent.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "scoped_team_worker"
  end

  policies do
    policy action([:start, :initialize, :__aikido_initialize_state__]) do
      authorize_if actor_present()
    end
  end
end

defmodule Aikido.RuntimeNativeContractTest.ScopedTeam do
  use Ash.Resource,
    domain: Aikido.RuntimeDomain,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "scoped_team"
  end

  team do
    member :worker, Aikido.RuntimeNativeContractTest.ScopedWorker
  end
end

defmodule Aikido.RuntimeNativeContractTest do
  use AikidoTest.Case, async: false

  test "a raw ActionResult cannot bypass validation before state or effects apply", %{
    aikido: instance
  } do
    {:ok, pid} =
      AikidoTest.Case.start_test_agent(
        instance,
        Aikido.RuntimeNativeContractTest.InvalidDirectiveAgent
      )

    assert {:error, _} =
             Aikido.AgentServer.call(pid, Aikido.Signal.new!("invalid.directive", %{}), fn _ ->
               {:ok, :accepted}
             end)

    assert {:ok, 0} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.count})
  end

  test "periodic synchronization writes changed state on the native interval", %{aikido: instance} do
    {:ok, pid} =
      AikidoTest.Case.start_test_agent(instance, AikidoTest.TestAgents.Counter,
        sync: %{mode: :periodic, interval_ms: 1_000}
      )

    :ok = Aikido.AgentServer.await_ready(pid)
    function = {Aikido.Durable.AgentServer, :dump_state, 1}
    :erlang.trace_pattern(function, true, [])
    :erlang.trace(pid, true, [:call])
    on_exit(fn -> :erlang.trace_pattern(function, false, []) end)

    assert {:ok, 1} =
             Aikido.AgentServer.call(
               pid,
               Aikido.Signal.new!("increment", %{amount: 1}),
               &{:ok, &1.agent.state.domain.counter}
             )

    assert_receive {:trace, ^pid, :call, {Aikido.Durable.AgentServer, :dump_state, _}}, 3_000
    refute :sys.get_state(pid).auto_sync
  end

  test "runtime reads and subscriptions do not dump snapshots, while state changes sync", %{
    aikido: instance
  } do
    {:ok, pid} =
      AikidoTest.Case.start_test_agent(instance, AikidoTest.TestAgents.Counter,
        sync: %{mode: :explicit}
      )

    :ok = Aikido.AgentServer.await_ready(pid)

    function = {Aikido.Durable.AgentServer, :dump_state, 1}
    :erlang.trace_pattern(function, true, [])
    :erlang.trace(pid, true, [:call])
    on_exit(fn -> :erlang.trace_pattern(function, false, []) end)

    assert {:ok, _} = Aikido.AgentServer.state(pid, &{:ok, &1.id})
    assert {:ok, subscription} = Aikido.AgentServer.subscribe(pid, "**", fn _ -> :skip end)
    :ok = Aikido.AgentServer.unsubscribe(pid, subscription)
    assert {:ok, _} = Aikido.AgentServer.state(pid, &{:ok, &1.id})
    delivered = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^delivered}
    refute_received {:trace, ^pid, :call, {Aikido.Durable.AgentServer, :dump_state, _}}

    assert {:ok, 2} =
             Aikido.AgentServer.call(
               pid,
               Aikido.Signal.new!("increment", %{amount: 2}),
               &{:ok, &1.agent.state.domain.counter}
             )

    assert_receive {:trace, ^pid, :call, {Aikido.Durable.AgentServer, :dump_state, _}}
  end

  test "callback dispatch subscribes before an immediately completed command", %{aikido: instance} do
    {:ok, pid} =
      AikidoTest.Case.start_test_agent(instance, AikidoTest.TestAgents.Counter,
        sync: %{mode: :explicit}
      )

    dispatch = fn ->
      Aikido.AgentServer.call(pid, Aikido.Signal.new!("increment", %{amount: 3}), fn _ ->
        {:ok, :receipt}
      end)
    end

    selector = fn runtime -> {:ok, runtime.agent.state.domain.counter} end
    assert {:ok, 3} = Aikido.AgentServer.call_until(pid, dispatch, "increment", selector)
    assert {:ok, 0} = Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})

    assert {:error, :denied} =
             Aikido.AgentServer.call_until(pid, fn -> {:error, :denied} end, "**", selector)
  end

  test "adopting a suspended child does not block the parent's mailbox", %{aikido: instance} do
    {:ok, parent} = AikidoTest.Case.start_test_agent(instance, AikidoTest.TestAgents.Minimal)
    {:ok, child} = AikidoTest.Case.start_test_agent(instance, AikidoTest.TestAgents.Minimal)
    :ok = :sys.suspend(child)

    try do
      assert {:ok, :sent} =
               Aikido.AgentServer.state(
                 parent,
                 fn runtime ->
                   :ok =
                     Aikido.Directive.exec(
                       %Aikido.Directives.AdoptChild{child: child, tag: :worker},
                       Aikido.Signal.new!("adopt", %{}),
                       runtime
                     )

                   {:ok, :sent}
                 end,
                 timeout: 1_000
               )

      assert {:ok, :responsive} = Aikido.AgentServer.state(parent, fn _ -> {:ok, :responsive} end)
    after
      :sys.resume(child)
    end

    assert {:ok, ^child} = Aikido.AgentServer.await_child(parent, :worker)
  end

  test "team member startup inherits the caller's Ash actor and authorization scope" do
    start_supervised!({Aikido, name: Aikido.Default, durable: AikidoTest.Case.durable_options()})

    assert {:ok, team} =
             Aikido.RuntimeNativeContractTest.ScopedTeam
             |> Ash.ActionInput.for_action(:start, %{},
               actor: %{id: "team-owner"},
               authorize?: true
             )
             |> Ash.run_action(actor: %{id: "team-owner"}, authorize?: true)

    assert {:ok, runtime} = Aikido.AgentServer.state(team.pid, &{:ok, &1})
    assert is_pid(runtime.agent.state.team.members.worker)
  end
end
