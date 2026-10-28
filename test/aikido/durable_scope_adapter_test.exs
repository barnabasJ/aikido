defmodule Aikido.DurableScopeAdapterTest do
  use AikidoTest.Case, async: false

  alias AikidoTest.{DurableScopeAgent, DurableScopeAuthority, LifecycleWait}

  for mode <- [:delegated, :autonomous] do
    @mode mode

    test "#{mode} fresh, saved and automatic restart use current authority without reinitializing",
         ctx do
      actor = actor(@mode)
      scope = scope(actor)
      id = Ash.UUIDv7.generate()
      pool = Aikido.durable_supervisor_name(ctx.aikido)
      assert {:ok, pid} = start(pool, id, actor, scope)
      assert :ok = Aikido.AgentServer.await_ready(pid)
      assert_receive {:durable_native_initialize, actor_id}
      assert actor_id == actor.id
      assert {:ok, ^actor} = boot_actor(pid)

      assert {:ok, ^pid} = start(pool, id, actor, scope(%{actor | revision: 999}))
      refute_receive {:durable_native_initialize, _}
      assert {:ok, ^actor} = boot_actor(pid)

      wrapper = :sys.get_state(pid).user_state

      saved =
        wrapper
        |> Aikido.Durable.AgentServer.dump_state()
        |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

      refute inspect(saved, limit: :infinity) =~ "never-persist-this-caller-secret"
      refute Keyword.has_key?(saved.options, :initialization_options)
      refute Keyword.has_key?(saved.options, :initial_state)
      assert {:agent, _} = saved.agent

      current = %{actor | revision: 2}
      :ok = DurableScopeAuthority.refresh_actor(current, "workspace")
      replacement = LifecycleWait.crash_and_await_replacement(pid)
      assert replacement != pid
      assert {:ok, ^current} = boot_actor(replacement)
      refute_receive {:durable_native_initialize, _}

      assert :ok = Aikido.Durable.stop(pool, replacement, scope: scope)
      assert {:ok, restored} = start(pool, id, actor, scope)
      assert :ok = Aikido.AgentServer.await_ready(restored)
      assert {:ok, ^current} = boot_actor(restored)
      refute_receive {:durable_native_initialize, _}
    end
  end

  test "a different caller cannot replace saved execution authority", ctx do
    alice = actor(:delegated)
    bob = actor(:delegated)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    assert {:ok, pid} = start(pool, id, alice, scope(alice))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert_receive {:durable_native_initialize, _}
    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope(alice))

    assert {:ok, restored} = start(pool, id, bob, scope(bob))
    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert {:ok, ^alice} = boot_actor(restored)
    refute_receive {:durable_native_initialize, _}
  end

  test "revoked credentials fail restore before lifecycle actions", ctx do
    actor = actor(:delegated)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    assert {:ok, pid} = start(pool, id, actor, scope(actor))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    credential = :sys.get_state(pid).user_state.credential
    assert_receive {:durable_native_initialize, _}
    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope(actor))
    assert :ok = DurableScopeAuthority.revoke(credential)
    assert {:error, _} = start(pool, id, actor, scope(actor))
    assert :error = Aikido.Durable.lookup(pool, id)
    refute_receive {:durable_native_initialize, _}
  end

  test "current permission revocation rejects an otherwise valid saved token", ctx do
    actor = actor(:autonomous)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    assert {:ok, pid} = start(pool, id, actor, scope(actor))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert_receive {:durable_native_initialize, _}
    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope(actor))
    assert :ok = DurableScopeAuthority.refresh_actor(%{actor | allowed: false}, "workspace")
    assert {:error, _} = start(pool, id, actor, scope(actor))
    assert :error = Aikido.Durable.lookup(pool, id)
    refute_receive {:durable_native_initialize, _}
  end

  test "idle binding and credential change together and survive restoration", ctx do
    alice = actor(:delegated)
    bob = actor(:autonomous)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    assert {:ok, pid} = start(pool, id, alice, scope(alice))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert_receive {:durable_native_initialize, _}
    wrapper = :sys.get_state(pid).user_state
    identity = Aikido.Durable.ScopeAdapter.identity(wrapper.options)

    assert {:ok, _, credential} =
             DurableScopeAuthority.prepare(
               %{state: %{actor_id: bob.id}},
               Map.to_list(scope(bob)),
               identity
             )

    signal =
      AikidoTest.DurableScopeAgent.Signals.Rebind.new!(
        %{actor_id: bob.id, credential: credential},
        scope: scope(bob)
      )

    assert {:ok, :rebound} =
             Aikido.AgentServer.call(pid, signal, fn runtime ->
               own = Aikido.Agent.resource_attributes(runtime.agent)
               assert own.actor_id == bob.id
               assert own.execution_credential == credential
               {:ok, :rebound}
             end)

    saved =
      :sys.get_state(pid).user_state
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

    assert saved.credential == credential
    assert {:agent, agent} = saved.agent
    assert Aikido.Agent.resource_attributes(agent).execution_credential == nil
    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope(bob))
    assert {:ok, restored} = start(pool, id, alice, scope(alice))
    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert {:ok, ^bob} = boot_actor(restored)
    refute_receive {:durable_native_initialize, _}
  end

  test "a signal actor mismatch does not adopt either identity or credential", ctx do
    alice = actor(:delegated)
    bob = actor(:autonomous)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    assert {:ok, pid} = start(pool, Ash.UUIDv7.generate(), alice, scope(alice))
    assert :ok = Aikido.AgentServer.await_ready(pid)

    signal =
      AikidoTest.DurableScopeAgent.Signals.Rebind.new!(
        %{actor_id: bob.id, credential: "untrusted"},
        scope: scope(alice)
      )

    assert {:error, _} = Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :unexpected} end)

    assert {:ok, {actor_id, nil}} =
             Aikido.AgentServer.state(pid, fn runtime ->
               own = Aikido.Agent.resource_attributes(runtime.agent)
               {:ok, {own.actor_id, own.execution_credential}}
             end)

    assert actor_id == alice.id
  end

  test "application rebind rejects invalid, revoked and foreign credentials before signal dispatch",
       ctx do
    alice = actor(:delegated)
    bob = actor(:autonomous)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    assert {:ok, pid} = start(pool, Ash.UUIDv7.generate(), alice, scope(alice))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    identity = :sys.get_state(pid).user_state.options |> Aikido.Durable.ScopeAdapter.identity()
    before = saved_envelope(pid)

    assert {:ok, _, revoked} =
             DurableScopeAuthority.prepare(
               %{state: %{actor_id: bob.id}},
               Map.to_list(scope(bob)),
               identity
             )

    assert :ok = DurableScopeAuthority.revoke(revoked)

    assert {:ok, _, foreign} =
             DurableScopeAuthority.prepare(
               %{state: %{actor_id: bob.id}},
               Map.to_list(scope(bob)),
               %{identity | id: "another-agent"}
             )

    for credential <- ["untrusted", revoked, foreign] do
      assert {:error, :invalid_or_revoked_credential} =
               DurableScopeAuthority.rebind(pid, bob, credential, identity)

      assert {:ok, {actor_id, nil}} =
               Aikido.AgentServer.state(pid, fn runtime ->
                 own = Aikido.Agent.resource_attributes(runtime.agent)
                 {:ok, {own.actor_id, own.execution_credential}}
               end)

      assert actor_id == alice.id
      assert saved_envelope(pid) == before
    end
  end

  test "authenticated idle rebind is dispatched through the application boundary", ctx do
    alice = actor(:delegated)
    bob = actor(:autonomous)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    assert {:ok, pid} = start(pool, Ash.UUIDv7.generate(), alice, scope(alice))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    identity = :sys.get_state(pid).user_state.options |> Aikido.Durable.ScopeAdapter.identity()

    assert {:ok, _, credential} =
             DurableScopeAuthority.prepare(
               %{state: %{actor_id: bob.id}},
               Map.to_list(scope(bob)),
               identity
             )

    assert {:ok, {actor_id, ^credential}} =
             DurableScopeAuthority.rebind(pid, bob, credential, identity)

    assert actor_id == bob.id
    assert saved_envelope(pid).credential == credential
  end

  test "adapter restoration honors native custom scope context and tracers", _ctx do
    actor = actor(:autonomous)
    identity = %{id: Ash.UUIDv7.generate()}
    context = %{shared: %{locale: "de-AT", marker: "protocol-context"}, custom: "full-context"}

    options = [
      actor: actor,
      tenant: "workspace",
      context: context,
      tracer: [AikidoTest.Support.TestTracer]
    ]

    attributes = %{state: %{actor_id: actor.id}}
    assert {:ok, _, credential} = DurableScopeAuthority.prepare(attributes, options, identity)

    assert {:ok, restored} =
             Aikido.Durable.ScopeAdapter.restore(
               AikidoTest.DurableProtocolAuthority,
               credential,
               {:uninitialized, attributes},
               identity
             )

    assert restored[:actor] == actor
    assert restored[:tenant] == "workspace"
    assert restored[:context] == context
    assert restored[:tracer] == [AikidoTest.Support.TestTracer]
    assert restored[:authorize?]

    assert {:ok, map_restored} =
             Aikido.Durable.ScopeAdapter.restore(
               DurableScopeAuthority,
               credential,
               {:uninitialized, attributes},
               identity
             )

    assert map_restored[:context] == context
    assert map_restored[:tracer] == [AikidoTest.Support.TestTracer]
  end

  test "stopped identity restores with empty bootstrap attributes and its saved credential",
       ctx do
    actor = actor(:autonomous)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    assert {:ok, pid} = start(pool, id, actor, scope(actor))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert_receive {:durable_native_initialize, _}
    credential = saved_envelope(pid).credential
    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope(actor))

    assert {:ok, restored} =
             Aikido.Durable.start(pool, id, agent: DurableScopeAgent, initial_state: %{})

    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert {:ok, ^actor} = boot_actor(restored)
    assert :sys.get_state(restored).user_state.credential == credential
    refute_receive {:durable_native_initialize, _}
  end

  test "missing fresh authority with empty attributes does not claim identity and valid retry succeeds",
       ctx do
    actor = actor(:delegated)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()

    assert {:error, :missing_execution_actor} =
             Aikido.Durable.start(
               pool,
               id,
               agent: DurableScopeAgent,
               initial_state: %{}
             )

    assert :error = Aikido.Durable.lookup(pool, id)
    assert {:ok, pid} = start(pool, id, actor, scope(actor))
    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, ^actor} = boot_actor(pid)
  end

  defp saved_envelope(pid) do
    :sys.get_state(pid).user_state
    |> Aikido.Durable.AgentServer.dump_state()
    |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))
  end

  test "concurrent activation runs native initialization only for the claimed identity", ctx do
    actor = actor(:delegated)
    scope = scope(actor)
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    tasks = for _ <- 1..2, do: Task.async(fn -> start(pool, id, actor, scope) end)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.any?(results, &match?({:ok, _}, &1))
    assert_receive {:durable_native_initialize, actor_id}
    assert actor_id == actor.id
    refute_receive {:durable_native_initialize, _}
    assert {:ok, pid} = Aikido.Durable.lookup(pool, id)
    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, ^actor} = boot_actor(pid)
  end

  defp start(pool, id, actor, scope) do
    Aikido.Durable.ensure_started(pool, id,
      agent: DurableScopeAgent,
      initial_state: %{state: %{actor_id: actor.id}},
      agent_opts: [initialization_options: Map.to_list(scope)]
    )
  end

  defp boot_actor(pid),
    do:
      Aikido.AgentServer.state(pid, &{:ok, Aikido.Agent.resource_attributes(&1.agent).boot_actor})

  defp actor(mode),
    do: %{id: Ash.UUIDv7.generate(), mode: mode, allowed: true, revision: 1}

  defp scope(actor) do
    %{
      actor: actor,
      tenant: "workspace",
      authorize?: true,
      context: %{shared: %{observer: self()}, credential: "never-persist-this-caller-secret"}
    }
  end
end
