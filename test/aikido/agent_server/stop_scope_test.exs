defmodule AikidoTest.StopScopeTest do
  use AikidoTest.Case, async: false
  alias AikidoTest.StopScope.Domain
  alias AikidoTest.LifecycleWait

  @moduletag capture_log: true

  setup do
    start_supervised!({Aikido, name: Aikido.Default, durable: AikidoTest.Case.durable_options()})
    :ok
  end

  test "a denied or absent stop actor cannot reuse startup authority and leaves cleanup unapplied" do
    agent = start_agent()

    assert {:ok, runtime} =
             Aikido.AgentServer.state(agent.pid, &{:ok, inspect(&1, limit: :infinity)})

    refute runtime =~ "never-retain-start-authority"

    for actor <- [nil, %{id: "denied", can_cleanup: false}] do
      assert {:error, _} = Domain.stoppable_stop(agent, actor: actor, authorize?: true)
      assert Process.alive?(agent.pid)

      assert %{cleanups: 0, cleanup_actor: nil, cleanup_tenant: nil} =
               Domain.stoppable_inspect!(agent)

      refute_received {:signal, %Aikido.Signal{type: "test.stop_scope.cleaned"}}
    end

    assert {:ok, _} = Domain.stoppable_stop(agent, actor: %{id: "permitted", can_cleanup: true})
    LifecycleWait.await_down(agent.pid)
    assert_receive {:signal, %Aikido.Signal{data: %{actor: "permitted", cleanups: 1}}}
  end

  test "public stop adopts cleanup and executes effects under its current actor and tenant" do
    agent = start_agent()
    actor = %{id: "current-stopper", can_cleanup: true}

    assert {:ok, _} =
             Domain.stoppable_stop(agent,
               actor: actor,
               tenant: "stop-tenant",
               context: %{
                 marker: "ordinary-stop-context",
                 credential: "never-retain-stop-context"
               },
               authorize?: true
             )

    LifecycleWait.await_down(agent.pid)

    assert_receive {:signal,
                    %Aikido.Signal{
                      type: "test.stop_scope.cleaned",
                      data: %{
                        actor: "current-stopper",
                        tenant: "stop-tenant",
                        cleanups: 1,
                        marker: "ordinary-stop-context"
                      },
                      scope: %{actor: ^actor, tenant: "stop-tenant"}
                    }}

    refute_received {:signal, %Aikido.Signal{type: "test.stop_scope.cleaned"}}

    restored = Domain.stoppable_start!(%{id: agent.id, observer: self()}, actor: starter())
    assert :ok = Aikido.AgentServer.await_ready(restored.pid)

    assert %{cleanups: 1, cleanup_actor: "current-stopper", cleanup_tenant: "stop-tenant"} =
             Domain.stoppable_inspect!(restored)
  end

  test "a routed Stop directive uses the current input signal's permitted scope" do
    agent = start_agent()
    actor = %{id: "signal-stopper", can_cleanup: true}

    assert {:ok, _} =
             Domain.stoppable_shutdown(agent, %{}, actor: actor, tenant: "signal-tenant")

    LifecycleWait.await_down(agent.pid)

    assert_receive {:signal,
                    %Aikido.Signal{
                      type: "test.stop_scope.cleaned",
                      data: %{actor: "signal-stopper", tenant: "signal-tenant", cleanups: 1},
                      scope: %{actor: ^actor, tenant: "signal-tenant"}
                    }}
  end

  test "a routed Stop directive reports denied cleanup and still terminates without cleanup effects" do
    agent = start_agent()

    assert {:error, _} =
             Domain.stoppable_shutdown(agent, %{}, actor: %{id: "denied", can_cleanup: false})

    LifecycleWait.await_down(agent.pid)
    refute_received {:signal, %Aikido.Signal{type: "test.stop_scope.cleaned"}}

    restored = Domain.stoppable_start!(%{id: agent.id, observer: self()}, actor: starter())
    assert :ok = Aikido.AgentServer.await_ready(restored.pid)
    assert %{cleanups: 0, cleanup_actor: nil} = Domain.stoppable_inspect!(restored)
  end

  defp start_agent do
    agent =
      Domain.stoppable_start!(%{observer: self()},
        actor: starter(),
        tenant: "start-tenant",
        context: %{
          credential: "never-retain-start-authority",
          aikido_runtime_options: [restart?: false]
        }
      )

    :ok = Aikido.AgentServer.await_ready(agent.pid)
    agent
  end

  defp starter, do: %{id: "starter", can_cleanup: true}
end
