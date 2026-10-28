defmodule Aikido.DurableClaimIdentityTest do
  use AikidoTest.Case, async: false

  alias AikidoTest.DurableScopeAgent

  @other_pool Aikido.DurableClaimIdentityTest.OtherPool

  for mode <- [:delegated, :autonomous], changed <- [:key, :partition, :pool] do
    @mode mode
    @changed changed

    test "#{mode} saved credentials reject a copied envelope with another #{changed}", ctx do
      original = save_authenticated_agent(ctx, @mode)
      target = changed_claim(original, @changed, ctx)

      assert {:error, _reason} = start_saved_envelope(target, original.saved)

      refute_receive {:durable_authentication, _identity}
      refute_receive {:durable_native_initialize, _actor_id}

      assert :error =
               Aikido.Durable.lookup(target.pool, target.id, partition: target.partition)

      assert :error =
               Aikido.Durable.lookup(original.pool, original.id, partition: original.partition)
    end
  end

  test "a saved envelope with its unchanged claimed identity restores through upstream start_child",
       ctx do
    original = save_authenticated_agent(ctx, :autonomous)

    assert {:ok, {pid, _metadata}} = start_saved_envelope(original, original.saved)
    assert :ok = Aikido.AgentServer.await_ready(pid)

    assert_receive {:durable_authentication, identity}
    assert identity.durable_server == original.pool
    assert identity.durable_key == original.id
    assert identity.partition == original.partition
    refute_receive {:durable_native_initialize, _actor_id}

    assert {:ok, actor} =
             Aikido.AgentServer.state(pid, fn runtime ->
               {:ok, Aikido.Agent.resource_attributes(runtime.agent).boot_actor}
             end)

    assert actor == original.actor
  end

  test "an existing-only activation cannot recreate a deleted snapshot or poison its key", ctx do
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    partition = "existing-only-partition"
    storage_key = Aikido.Durable.storage_key(id, partition)

    error =
      assert_raise Aikido.Durable.ScopeAdapter.Error, fn ->
        Aikido.Durable.AgentServer.dump_state(%{require_existing?: true})
      end

    assert error.operation == :restore
    assert error.reason == :saved_state_missing

    case DurableServer.Supervisor.start_child(
           pool,
           {Aikido.Durable.AgentServer,
            key: storage_key, initial_state: %{require_existing?: true}}
         ) do
      {:error, :noproc} ->
        :ok

      {:error,
       {%Aikido.Durable.ScopeAdapter.Error{operation: :restore, reason: :saved_state_missing},
        stack}}
      when is_list(stack) ->
        :ok

      other ->
        flunk("Unexpected existing-only activation result: #{inspect(other)}")
    end

    native = DurableServer.Supervisor.__get_config__(pool)

    assert {:error, :not_found} =
             DurableServer.fetch_stored_state(
               pool,
               %{key: storage_key, prefix: native.prefix},
               consistent: true
             )

    refute_receive {:durable_authentication, _identity}
    refute_receive {:durable_native_initialize, _actor_id}
    refute match?({:ok, _}, DurableServer.Supervisor.get_server_info(pool, storage_key))
    assert :error = Aikido.Durable.lookup(pool, id, partition: partition)

    actor = %{id: Ash.UUIDv7.generate(), mode: :autonomous, allowed: true, revision: 1}

    scope = %{
      actor: actor,
      tenant: "workspace",
      authorize?: true,
      context: %{shared: %{observer: self()}}
    }

    assert {:ok, pid} =
             Aikido.Durable.ensure_started(pool, id,
               agent: DurableScopeAgent,
               partition: partition,
               initial_state: %{state: %{actor_id: actor.id}},
               agent_opts: [initialization_options: Map.to_list(scope)]
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert_receive {:durable_authentication, identity}
    assert identity.durable_key == id
    assert identity.partition == partition
    assert_receive {:durable_native_initialize, actor_id}
    assert actor_id == actor.id
    assert {:ok, ^pid} = Aikido.Durable.lookup(pool, id, partition: partition)
    assert {:ok, _info} = DurableServer.Supervisor.get_server_info(pool, storage_key)
  end

  defp save_authenticated_agent(ctx, mode) do
    pool = Aikido.durable_supervisor_name(ctx.aikido)
    id = Ash.UUIDv7.generate()
    partition = "source-partition"
    actor = %{id: Ash.UUIDv7.generate(), mode: mode, allowed: true, revision: 1}

    scope = %{
      actor: actor,
      tenant: "workspace",
      authorize?: true,
      context: %{shared: %{observer: self()}}
    }

    assert {:ok, pid} =
             Aikido.Durable.ensure_started(pool, id,
               agent: DurableScopeAgent,
               partition: partition,
               initial_state: %{state: %{actor_id: actor.id}},
               agent_opts: [initialization_options: Map.to_list(scope)]
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert_receive {:durable_authentication, identity}
    assert identity.durable_server == pool
    assert identity.durable_key == id
    assert identity.partition == partition
    assert_receive {:durable_native_initialize, actor_id}
    assert actor_id == actor.id

    saved =
      :sys.get_state(pid).user_state
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(nil, &1))

    assert {:agent, _agent} = saved.agent
    assert is_binary(saved.credential)
    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope)

    %{pool: pool, id: id, partition: partition, actor: actor, saved: saved}
  end

  defp changed_claim(original, :key, _ctx),
    do: %{original | id: "copied/" <> original.id}

  defp changed_claim(original, :partition, _ctx),
    do: %{original | partition: "another-partition"}

  defp changed_claim(original, :pool, ctx) do
    options =
      durable_options()
      |> Keyword.merge(name: @other_pool, aikido: ctx.aikido)

    start_supervised!({Aikido.Durable, options})
    %{original | pool: @other_pool}
  end

  defp start_saved_envelope(target, saved) do
    DurableServer.Supervisor.start_child(
      target.pool,
      {Aikido.Durable.AgentServer,
       key: Aikido.Durable.storage_key(target.id, target.partition), initial_state: saved}
    )
  end
end
