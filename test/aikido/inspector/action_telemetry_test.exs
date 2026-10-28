defmodule AikidoTest.Inspector.ActionTelemetryTest do
  use AikidoTest.Case, async: false

  alias Aikido.Inspector.History

  test "native materialization runs while only generated and explicit reducers enter action history",
       context do
    namespace = Ash.Domain.Info.short_name(AikidoTest.AshFixtures.Domain)
    assert Ash.Domain.Info.short_name(AikidoTest.TeamStopScope.Domain) == namespace

    assert Ash.Resource.Info.domain(AikidoTest.TeamStopScope.Member) !=
             Ash.Resource.Info.domain(AikidoTest.AshFixtures.Counter)

    actor = %{id: "telemetry-domain-owner", can_cleanup: true}

    {:ok, other} =
      start_test_agent(context.aikido, AikidoTest.TeamStopScope.Member,
        initial_state: %{observer: self()},
        initialization_options: [actor: actor, authorize?: true]
      )

    assert :ok = Aikido.AgentServer.await_ready(other)

    assert {:ok, _} =
             AikidoTest.TeamStopScope.Domain.scope_member_stop(other,
               actor: actor,
               authorize?: true
             )

    AikidoTest.LifecycleWait.await_down(other)

    scenarios = [
      {AikidoTest.TestAgents.Counter, "increment", :domain, :counter,
       "AikidoTest.TestActions.Actions.IncrementCounter"},
      {AikidoTest.AshFixtures.Counter, "counter.increment", :state, :count,
       "AikidoTest.AshFixtures.Counter.Actions.Increment"}
    ]

    for {resource, type, path, field, implementation} <- scenarios do
      {:ok, pid} = start_test_agent(context.aikido, resource)

      {:ok, reference} =
        Aikido.AgentServer.subscribe(
          pid,
          type,
          fn runtime, event ->
            {:ok,
             %{
               own: Map.fetch!(runtime.agent.state, path),
               execution: History.project_event(event, resource)
             }}
          end,
          once: true
        )

      handler = {__MODULE__, make_ref()}
      domain = Ash.Resource.Info.domain(resource) || Aikido.RuntimeDomain
      event = [:ash, Ash.Domain.Info.short_name(domain), :action, :stop]

      :ok =
        :telemetry.attach(
          handler,
          event,
          fn _, _, metadata, observer ->
            if metadata.resource == resource and metadata.action == :__aikido_snapshot__,
              do: send(observer, {:native_materialization, resource})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      Aikido.AgentServer.cast(
        pid,
        Aikido.Signal.new!(type, %{amount: 7, secret: "private action input"})
      )

      assert_receive {:aikido_subscription, ^reference, %{result: {:ok, observed}}}, 5_000
      assert Map.fetch!(observed.own, field) == 7
      assert_receive {:native_materialization, ^resource}, 5_000
      assert observed.execution.action_count == 1
      assert [action] = observed.execution.actions
      assert action.resource == inspect(resource)
      assert action.implementation == implementation
      assert action.mount_paths == [Atom.to_string(path)]
      assert is_number(action.duration_ms) and action.duration_ms >= 0
      refute Map.has_key?(action, :arguments)
      refute Map.has_key?(action, :result)
      refute inspect(action) =~ "private action input"
    end
  end
end
